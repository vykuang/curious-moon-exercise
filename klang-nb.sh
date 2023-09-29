#! /usr/bin/env sh
. ./activate && nohup jupyter lab --no-browser &
sleep 10
tail nohup.out | grep http
