# psql commands

## Shell CLI

To connect from shell:

```sh
psql \
    --host=HOSTNAME \
    --port=PORT \
    --username=USERNAME \
```

After which it will prompt you for the database user password

### common commands

- --dbname - database to connect to
- --file=FILENAME - execute .sql from file
- --list - list databases available on server

## Database CLI
Common commands for `psql` CLI once you're connected to the database

- \C
- \l - list database
- \d - list tables inside the database
- \h some_sql_command - help on that specific cmd
- \c DB_NAME - connect to that db
- \H - output in html
- \o FILE_NAME - redirects from STDOUT (terminal) to specified filename; usually used with \H