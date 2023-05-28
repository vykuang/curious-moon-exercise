# Notes from curious moon

## Setup

`docker compose build && docker compose -d up` to run the postgres and pgadmin containers

If psql is installed locally, can connect to the container since the 5432 port is exposed:

```sh
psql \
    -U postgres \
    -h localhost \
    -p 5432
```

after which the shell will prompt for password that's set in `.env`


### table edit

```sql
drop table if exists enceladus;
create table enceladus(
    id serial primary key,
    the_date date,
    title varchar(100),
    description text
);
```

- `drop table if exists` reduces complication when it comes to errors
- `serial` is an always increasing unique sequence to use as primary key
    - shorthand from psql
    - ANSI sql may use `create sequence id_sq` and then get `nextval('id_sq')` as the primary key
- primary key in ansi: `add constraint enceladus primary key (id);`

### master schedule

Due to budget cuts, each cassini flyby could only operate one or two sensors instead of the originally planned ensemble. Thus the master schedule was borne, to plan the entire operation down to the second.

### Importing CSVs

- correct typing - each column must have defined type
- completeness - not every row may be complete
- accuracy - even if each field was filled and had the correct typing, they might not make sense in context; can't have negative kelvins.

Importing CSVs or any other data sources must define the protocol for when any one of those criteria are not met, and must require input from stakeholders, e.g. data producer and data consumer

#### Mechanics

start simple, until it doesn't work. In order of complexity:

- shell scripts/Make files
- python's pandas for more complex functions
- kafka for streaming?

Import everything as _text_ first; get the data in db, _then_ get the typing right

`COPY FROM` reads file from disk to database

*Idempotency* must be maintained so that the pipeline can be repeated while arriving at the same result; loading a table should not add a new table the next time

### Idempotency

`build.sql` contains our load script, where we load the csv entirely as text

```sql
-- build.sql part 1
drop table if exists master_plan;
create table master_plan(
    start_time_utc text,
    ... text,
    ...,
);
```

this creates the empty table with all text types

next, load our csv with COPY FROM

```sql
-- build.sql part 2
COPY master_plan
FROM 'path/to/master-plan.csv' -- note single quotes
-- delimiter: ','; there is header row; csv type
WITH DELIMITER ',' HEADER CSV;
```

Next we define the _schema_, a de facto namespace feature. Namespace hierarchy in postgres goes:

- cluster - set of servers
- database
- schemas
  - default schema is `public`
- tables, views, functions; all fall under a schema
  - in bigquery this is called _dataset_

so much like we don't commit directly to `main` in git, we create a schema for our raw text table:

```sql
-- build.sql part 0
create schema if not exists import;
drop table if exists import.master_plan;
create table ...
COPY import.master_plan ...
```

Execute in psql: `psql enceladus -f build.sql`

Confirm table with `select * from import.master_plan limit 5;`, don't forget the `;`

### Make

makefile consists of these components

- target - top level names for things you want to happen
- recipe - commands under `target` that accomplishes the things you want to happen
  - must be indented with _tab_, new spaces, as many editors are wont to do
- prerequisite - each target may have a pre-req, which are other targets that needs to happen first
- variables - could be assigned at the top to parametrize the makefile

Common targets:

- all: default target; executed if no target specified when calling `make`
- clean: teardown, removing build artifacts and cleaning out build dir. Deletes `build.sql`; works if we use our makefile to build a new `build.sql` each time it's called
- .PHONY: not really sure

Parametrize

- `${CURDIR}` returns where `make` is being called, which is useful since psql requires absolute paths when specifying the `build.sql` location

Starting makefile:

```make
DB=enceladus
BUILD=${CURDIR}/build.sql
SCRIPTS=${CURDIR}/scripts
CSV='${CURDIR}/data/master_plan.csv'
MASTER=$(SCRIPTS)/import.sql
NORMALIZE = $(SCRIPTS)/normalize.sql

all: normalize
    psql $(DB) -f $(BUILD)

master:
    @cat $(MASTER) >> $(BUILD)

import: master
    @echo "COPY import.master_plan FROM
$(CSV) WITH DELIMITER ',' HEADER CSV;" >> $(BUILD)

normalize: import
    @cat $(NORMALIZE) >> $(BUILD)

clean:
    @rm -rf $(BUILD)
```

`make clean && make` will now build the script from scratch, and re-run it

Make  also allows us to compartmentalize the sql commands

- import.sql - create import schema and load csv
- normalize.sql - split the raw imported table into whatever smaller tables we need

### Common psql commands

- \l - list database
- \d - list tables inside the database
- \h - help
  - -h some_sql_command - help on that specific cmd

## Orbit

### Normalization

Normalization reduces repetition and thus disk usage. Essentially we're creating lookup tables. To make lookup tables:

1. get all distinct values from import
1. create new table with those distincts
1. add primary key for use with foreign key constraint

fields like team, spass, targets don't have many distincts, but requests and libs have hundreds/thousands. Even so we can make lookup tables for each of those types. They all need to relate back to the source table, i.e. `fact` table, a la *star schema*

### Importing events

Create fact table for events in public schema, where it will be globally accessible. Since this is not imported directly from csv, we can type the fields

```sql
create table events(
id serial primary key,
time_stamp timestamptz not null,
title varchar(500),
description text,
event_type_id int,
spass_type_id int,
target_id int,
team_id int,
request_id int
);
```

- No null constraints, _except for timestamp_; anywhere else should be able to accept null
- when pulling from `import.master_plan`, remember to cast the fields, e.g. `date::timestamptz` to convert our string date into timezoned timestamp
- how do we know that the field can be safely cast to the type we want? we don't really until we examine it, or try:
  - `select date::timestamptz from import.master_plan` will fail; 
  - something inside is formatted wrong
  - definitely ran into this multiple times when loading into bigquery

### datetimes

pain to deal with. NASA apparently uses `year-dayofyear` format to avoid leapyear bs

postgres always stores in UTC, until retrieved; at which point it converts to whatever timezone is set in config, which by default is determined from server location

When using `timestamptz`, specify the timezone, otherwise, again, postgres will assume server loc timezone which may not be what we need. Specify by `2001-01-01::timestamptz at time zone 'UTC'`

Instead of `date`, import `start_time_utc` and specify utc timezone

```sql
insert into events(
    time_stamp,
    title,
    description
)
select
    start_time_utc::timestamp at time zone 'UTC',
    title,
    description
from import.master_plan;
```

### Lookup tables

Point of these is so that we replace the distinct values with some integer, which maps to the actual text name in that field's lookup. I.e. for `team`, the `team` lookup will have unique team names as primary key, and then some integer that correponds to each. Now our models can rely on this lookup and use integer to represent each team instead of full varchar. This could potentially speed up compute since comparisons are done with nums instead of texts.

Caveat is that with the reduced cost of storage, and decoupling of storage/compute, this has a lower cost impact than before.

Execution:

```sql
-- idempotency
drop table if exists team;
-- create lookup
select distinct(team) as description 
into teams 
from import.master_plan;

-- add primary key
alter table teams
add id serial primary key;
```

repeat for other lookups, with this pattern:

- using integer `id` as primary
- `description` as text
- not using repetitive naming scheme, e.g. `teams.team`

Relating lookup back to the events fact table can be tricky. Or well just a lot of joins.

```sql
insert into events(
    time_stamp,
    title,
    description,
    event_type_id,
    target_id
    ...
)
select
    timestamp,
    ...
    event_types.id as event_type_id,
    targets.id as target_id,
    ...
from import.master_plan
left join event_types
    on event_types.description = import.master_plan.library_definition
...
-- repeat for each lookup
;
```

Left join is particularly important; this keeps all data in the `from` table, and pads nonmatches with nulls.

Now that we have all our lookups, we can leverage it in our `create table events` statement with `references`:

```sql
create table events(
    event_type_id int references event_types(id)
    ...)
```

`references` creates a foreign key constraint on the `event_type_id` field: all values here must be one of the `id` values in `event_types` lookup. It's a form of data validation

Now put it all together.

- scripts/create_table_master_plan.sql creates import schema and master_plan table
- scripts/normalize.sql creates the lookups, creates the event table, and jam data from master_plan via lookups
- need to fill out the scripts

## Flyby

Cassini had 23 (or perhaps 22) flybys to Enceladus. Find the precise times of the closest approach for each flyby. Doesn't NASA already know this?

search from `events` table where `title ILIKE '%flyby&' OR title ILIKE '&fly by&'` and include targets so we can filter for enceladus

Spot check the data vs ground truth, i.e. `import.master_plan`; first enceladus flyby should be in feb 17, 2005

Apparently that first flyby was called "obtain wideband examples of lightning whistlers", and target was "Saturn", not "Enceladus"???

### Sargeable vs non-sargeable

SARG is short for **search argument**. Sargable means that the database is able to perform an *index seek* to match the search predicate. If we're searching by an integer the engine could sort by that integer column, and automatically *seek* to that row without scanning every row.

Non-sargable means that the database is not able to use index seek, i.e. it must perform some SQL function, e.g. `WHERE UPPER(name) LIKE 'CASSINI'`. The storage engine must return all rows to SQL engine for intermediate evaluation before searching. This becomes a sequential scan; all rows must be evaluated.

### Materialized views

Not an actual table; just stored snippets of SQL. Create with:

```sql
drop view if exists enceladus_events;
create view enceladus_events as
select
    events.time_stamp,
    events.time_stamp::date as date,
    event_types.description as event
from events
inner join event_types
on event_types.id = events.event_type_id
where target_id=28
order by time_stamp;
```

Creating a view does not execute it, unlike creating a table; the view SQL only executes when it is queried against.

### full-text indexing

Prioritize useful terms and deprioritize *noise*. Critical when searching through our `title` or `description` columns in a large database.

In postgres, `to_tsvector(events.description)` is a function that indexes the string column. To make use of this indexed string column, use this in a where clause: `where search @@ to_tsquery('thermal')`. That will show all matches; other operators besides `@@` will do different things

### First flyby

Via historical context (i.e. domain knowledge), we know that feb 17 2005 was definitely first flyby. Time to identify it in our facts table, i.e. `events`

Look in events, and put back the text description by joining the dimension tables for manual inspection. This way we find out how the scientists actually labelled their flyby:

```sql
select
    targets.description as target,
    events.time_stamp,
    event_types.description as event
from events
inner join event_types on event_types.id = events.event_type_id
inner join targets on targets.id = events.target_id
where events.time_stamp::date = '2005-02-17'
order by events.time_stamp;
```

This looks for all events on that date, with original target and event type descriptions as string.

One line reads: `Enceladus closest approach observation` with `Enceladus` as target, so let's put that restriction: `targets.description ILIKE 'enceladus'`. However instead of doing a slow string query, we can find what the target ID integer is via `select * from targets where description = 'Enceladus'` (28 for me; 40 in the book) and perform an index search. Cuts time in half from 94 to 55 ms; non-sargeable vs sargeable.

The flyby unexpectedly revealed some signs of an atmosphere. Second flyby threw all their instruments at it. The most active team on the 2005-03-09 flyby was CIRS (composite infared scanner), followed by UVIS (ultraviolet imaging spectrograph subsystem), to take UV images, then VIMS for infrared. This avalanche of readings confirmed that Enceladus indeed posessed an atmosphere

## psql commands

- \c DB_NAME - connect to that db
- \H - output in html
- \o FILE_NAME - redirects from STDOUT (terminal) to specified filename; usually used with \H