require "../src/cron_parser"

N = (ARGV[0]? || 10).to_i
t11 = Time.new 2015, 10, 12, 18, 33, 0

t = Time.now
s = 0
(1000 * N).times do |i|
  cron_parser = CronParser.new("#{i % 60} #{i % 24} * * *")
  s += (cron_parser.next(t11) - t11).to_f / 100_000.0
end
p s
p (Time.now - t).to_f

t = Time.now
s = 0
N.times do |i|
  cron_parser = CronParser.new("30 #{i % 24} * * *")

  # Comming times
  s += cron_parser.nexts(t11, 100 * 100).size
  s += cron_parser.lasts(t11, 100 * 100).size
end

p s
p (Time.now - t).to_f
