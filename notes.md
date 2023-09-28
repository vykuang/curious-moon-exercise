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

### Materialized views and indexing

View is not an actual table; just stored snippets of SQL. Create with:

```sql
drop view if exists enceladus_events;
create view enceladus_events as
select
    events.time_stamp,
    events.time_stamp::date as date,
    event_types.description as event,
    to_tsvector(concat(
        events.description, ' ',
        events.title)
    ) as search
from events
inner join event_types
on event_types.id = events.event_type_id
where target_id=28
order by time_stamp;
```

**Materialized** views are similar, and the also allow indexing which improves search performance:

```sql
create index idx_event_search
on enceladus_events using GIN(search)
```

Now when we search using `to_tsquery` it won't need to go through every item

Creating a view does not execute it, unlike creating a table; the view SQL only executes when it is queried against.

### full-text indexing

Prioritize useful terms and deprioritize *noise*. Critical when searching through our `title` or `description` columns in a large database.

In postgres, `to_tsvector(events.description)` is a function that indexes the string column. To make use of this indexed string column, 

1. create view with that `to_tsvector(events.description) as search`
2. use new `search` column in a where clause: `where search @@ to_tsquery('thermal')`. That will show all matches for `thermal`; other operators besides `@@` will do different things.

Combine `concat()` with `to_tsvector` to search through two different text columns: `to_tsvector(concat(events.description, ' ', events.title))`

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

### all closest flybys

Use `concat` with `to_tsvector` to search for `closest` in description *and* title:

```sql
drop view if exists enceladus_events;
create materialized view enceladus_events as
select
    events.id,
    events.title,
    events.description,
    events.time_stamp,
    events.time_stamp::date as date,
    event_types.description as event,
    to_tsvector(
        concat(events.description, ' ', events.title)
    ) as search
from events
inner join event_types
on event_types.id = events.event_type_id
where target_id=28
order by time_stamp;

/-- create index on our search column
create index idx_event_search
on enceladus_events using GIN(search)


/-- search for closest
select * from enceladus_events
where search @@ to_tsquery('closest')
```

This returns two closest flybys on 2009-11-02. Data entry error? Two actual flybys? It's possible the data may not be as reliable as hoped. Turn to a different dataset? Try INMS.

## INMS

The Ion Neutral Mass Spectrometer sniffs space to analyze what chemicals are out there. It ionizes matter with electron beam and produces a spectrum via a quadrupole (collection of four steel rods with electrical currents running through). As part of the analysis metadata, positional data is recorded. Cross-referenced with the mission plan, we can find the closest flybys.


### dataset structure

due to the large size, need to be selective on which files to use. INMS is separated to folders of years, months, days of year, and then a mess of CSVs. We need to limit our search by figuring out the year/day of year for each suspected flyby. Use our `enceladus_events` materialized view

```sql
select 
    date_part('year', date), 
    to_char(time_stamp, 'DDD')
from enceladus_events
where event like '%closest%'
order by time_stamp;
```

The dataset includes a FMT file which is a manifest describes the CSV columns

- `ALT_T` - altitude of spacecraft above target body within 1 hour of closest flyby
- `TARGET` - target body

Search for `TARGET = 'enceladus` and look for lowest `ALT_T`?

### CSVs and bash

- `ls ./**/*/.csv | wc -l`
  - lists all CSVs, pipe output to wordcount, count only lines
  - return num of CSVs
  - loop over each CSV and run `COPY FROM`?
  - or concat into single CSV, then import?
  - second is better to avoid partially copied table, in case of failure
- `cat ./**/*.csv > inms.csv`
  - what are the CSV headers?
    - rows 1-3 are headers
    - remove from each CSV?
    - import as is and remove with SQL
  - do all CSVs have same headers
- `csvkit` has useful tools for importing CSVs to db
  - `csvsql` takes a csv and generate a `CREATE TABLE` SQL statement
    - defaults all the VARCHAR but it takes up more space than TEXT
    - TEXT is same as VARCHAR in postgres, but has no length check and so is faster
    - use `sed` to convert VARCHAR to text

```bash
csvsql 2005/048/200504800_L1A_05.csv \
    -i postgresql \
    --tables "import.inms" \
    --no-constraints \
    -overwrite | sed 's/VARCHAR/text/g' > import.sql
```

Use this template to 

- add `DROP ... IF EXISTS`
- `COPY FROM` at the end
- change table name; we want to create this in the `import` schema, but if we run `import.sql` it will create `import.inms` in `public` schema, so we'll change the `import.sql` file manually to correct for this

#### error: extra data

2015 suddenly added a bunch of new columns which failed the import, since we used 2005 csv as the template to create our table. Manifest explains the new columns.

Options:

1. cut the extra columns - `cut -d -f2 --complement inms.csv`
1. load 2015 as separate table?
1. just cut the extra columns from 2015 csv

```bash
cat 2015/**/*.csv > 2015.csv
cut -d ',' -f<col_idx_to_cut> 2015.csv > inms_2.csv

# manually move all other years into ./good/
cat good/**/*.csv > inms_1.csv

# combine to one
cat inms_1.csv inms_2.csv > inms.csv
```

### INMS data inspection

- Remove all the header rows with SQL
- remove all entries without `sclk`, or spacecraft clock, data
- try to look for all entries with enceladus as target

```sql
drop materialized view if exists flyby_altitudes;
create materialized view flyby_altitudes as
select
    (sclk::timestamp) as time_stamp,
    alt_t::numeric(10,3) as altitude
from import.inms
where target='ENCELADUS'
and alt_t IS NOT NULL;
```

if all goes well, create materialized view

#### nadirs

To find the closest flyby from `flyby_altitudes`, we look for `min(altitude)` grouped by weeks, given that flybys must be at least a week apart for cassini to fly around saturn.

```sql
select
    date_part(‘year’,time_stamp) as year,
    date_part(‘week’,time_stamp) as week,
    min(altitude) as altitude
from flyby_altitudes
group by
    date_part(‘year’,time_stamp),
    date_part(‘week’,time_stamp)
```

Next, find the exact `time_stamp` associated with each nadir using a CTE

However due to the speed of Cassini, multiple timestamps are associated with each flyby's min altitude. Without any additional context, the next best thing is to take the average of all the timestamps associated with each nadir

```sql
with lows_by_weeks as 
    (select 
        date_part('year', time_stamp) as year,
        date_part('week', time_stamp) as week,
        min(altitude) as alt
    from flyby_altitudes
    group by 
        date_part('year', time_stamp),
        date_part('week', time_stamp)
    ), 
nadirs as (
    select 
        f.time_stamp,
        l.alt
    from lows_by_weeks l
    inner join flyby_altitudes f
    on l.alt = f.altitude
)
select 
    min(time_stamp) + (max(time_stamp) - min(time_stamp))/2 time_stamp_avg,
    alt
from nadirs
group by 
    alt -- don't group by dates a second time
order by time_stamp_avg;
```

duplicates showing up for 2011-10-01 and 2012-04-14??? don't group by dates again in the last query

## Ring Dust

Nadirs are where plumes are most concentrated, saturating the INMS and CDA sensors, creating windows where sensors are more prone to error. If we have the speeds, analyses can use them to compensate for offset

Create `flybys` table with timestamp and altitude, along with speed, start_time, and end_time

### Cosmic dust analyzer (CDA)

Cassini is comprised of two components - cassini deep-space probe, and huygens, a one-way lander for Titan

CDA itself is also made of two parts - dust analyzer and high rate detector; one for big, fast particles, the other for high volume. We want dust analyzer for their physical and chemical analyses. It zaps the dusts into plasma and analyzes the zap profile

Redo the materialized view to include the group by year and dates to simplify the resulting CTE

```sql
-- create view
drop materialized view if exists flyby_altitudes;
create materialized view flyby_altitudes as 
select
    (sclk::timestamp) as time_stamp,
    date_part('year', (sclk::timestamp)) as year,
    date_part('week', (sclk::timestamp)) as week,
    alt_t::numeric(10,3) as altitude
from import.inms
where target='ENCELADUS' and alt_t IS NOT NULL;
```

Our flybys become

```sql
with lows_by_weeks as 
    (select 
        min(altitude) as alt
    from flyby_altitudes
    group by year, week 
    ), 
nadirs as (
    select 
        f.time_stamp,
        l.alt
    from lows_by_weeks l
    inner join flyby_altitudes f
    on l.alt = f.altitude
)
select 
    min(time_stamp) + (max(time_stamp) - min(time_stamp))/2 time_stamp_avg,
    alt
from nadirs
group by 
    alt -- don't group by dates a second time
order by time_stamp_avg;
```

### functions

Calcs in SQL is a type of code smell. Use **functions** to abstract them out

```sql
drop function if exists low_time(
    numeric,
    double precision,
    double precision
);
create function low_time(
    alt numeric,
    yr double precision,
    wk double precision,
    out timestamp without time zone
)
as $$
    select
        min(time_stamp) + (max(time_stamp) - min(time_stamp))/2 nadir
    from flyby_altitudes f
    where f.altitude=alt
    and f.year = yr
    and f.week = wk
$$ language sql;
```

- drop isn't required but makes editing easier
- $$ encloses the function body
- output contains the query results

New CTE:

```sql
with lows as (
    select
        year,
        week,
        min(altitude) as altitude
    from flyby_altitudes
    group by year, week
)
select 
    low_time(altitude, year, week) as time_stamp,
    altitude
from lows;
```

### flybys table

add start_time, end_time, and assign primary key

## psql commands

- \c DB_NAME - connect to that db
- \H - output in html
- \o FILE_NAME - redirects from STDOUT (terminal) to specified filename; usually used with \H