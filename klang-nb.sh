#! /usr/bin/env sh
. /home/klang/.local/share/virtualenvs/code-practice-op8MSIhg/bin/activate && nohup jupyter lab --no-browser &
sleep 10
tail nohup.out | grep localhost 
docker compose run --rm -d --service-ports --name curiousdb db
