# cron_parser

Cron parser for Crystal language. Translated from Ruby https://github.com/siebertm/parse-cron. It is parse a crontab timing specification and determine when the job should be run. It is not a scheduler, it does not run the jobs.

## Installation


Add this to your application's `shard.yml`:

```yaml
dependencies:
  cron_parser:
    github: kostya/cron_parser
```


## Usage


```crystal
require "./src/cron_parser"

cron_parser = CronParser.new("30 * * * *")

# Comming times
p cron_parser.next(Time.now)
p cron_parser.nexts(Time.now, 5)

# Times that have been
p cron_parser.last(Time.now)
p cron_parser.lasts(Time.now, 5)
```

