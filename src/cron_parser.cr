require "set"

# Parses cron expressions and computes the next occurence of the "job"
#
class CronParser
  # internal "mutable" time representation
  class InternalTime
    property :year, :month, :day, :hour, :min
    property :time_source

    def initialize(time, time_source = Time)
      @year = time.year
      @month = time.month
      @day = time.day
      @hour = time.hour
      @min = time.minute

      @time_source = time_source
    end

    def to_time
      Time.new(@year, @month, @day, @hour, @min, 0, 0, Time::Kind::Local)
    end

    def inspect
      [year, month, day, hour, min].inspect
    end
  end

  SYMBOLS = {
    "jan" => "1",
    "feb" => "2",
    "mar" => "3",
    "apr" => "4",
    "may" => "5",
    "jun" => "6",
    "jul" => "7",
    "aug" => "8",
    "sep" => "9",
    "oct" => "10",
    "nov" => "11",
    "dec" => "12",

    "sun" => "0",
    "mon" => "1",
    "tue" => "2",
    "wed" => "3",
    "thu" => "4",
    "fri" => "5",
    "sat" => "6",
  }

  def initialize(source, time_source = Time)
    @source = interpret_vixieisms(source)
    @time_source = time_source
    @_interpolate_weekdays_cache = {} of String => Tuple(Set(Int32), Array(Int32))
    validate_source
  end

  def interpret_vixieisms(spec)
    case spec
    when "@reboot"
      raise ArgumentError.new("Can't predict last/next run of @reboot")
    when "@yearly", "@annually"
      "0 0 1 1 *"
    when "@monthly"
      "0 0 1 * *"
    when "@weekly"
      "0 0 * * 0"
    when "@daily", "@midnight"
      "0 0 * * *"
    when "@hourly"
      "0 * * * *"
    else
      spec
    end
  end

  # returns the next occurence after the given date
  def next(now = @time_source.now)
    t = InternalTime.new(now, @time_source)

    unless time_specs[:month][0].includes?(t.month)
      nudge_month(t)
      t.day = 0
    end

    unless interpolate_weekdays(t.year, t.month)[0].includes?(t.day)
      nudge_date(t)
      t.hour = -1
    end

    unless time_specs[:hour][0].includes?(t.hour)
      nudge_hour(t)
      t.min = -1
    end

    # always nudge the minute
    nudge_minute(t)
    t.to_time
  end

  def nexts(now = @time_source.now, num = 1)
    res = [] of Time
    n = self.next(now)
    res << n
    (num - 1).times do
      n = self.next(n)
      res << n
    end
    res
  end

  # returns the last occurence before the given date
  def last(now = @time_source.now)
    t = InternalTime.new(now, @time_source)

    unless time_specs[:month][0].includes?(t.month)
      nudge_month(t, :last)
      t.day = 32
    end

    if t.day == 32 || !interpolate_weekdays(t.year, t.month)[0].includes?(t.day)
      nudge_date(t, :last)
      t.hour = 24
    end

    unless time_specs[:hour][0].includes?(t.hour)
      nudge_hour(t, :last)
      t.min = 60
    end

    # always nudge the minute
    nudge_minute(t, :last)
    t = t.to_time
  end

  def lasts(now = @time_source.now, num = 1)
    res = [] of Time
    n = self.last(now)
    res << n
    (num - 1).times do
      n = self.last(n)
      res << n
    end
    res
  end

  SUBELEMENT_REGEX = %r{^(\d+)(-(\d+)(/(\d+))?)?$}

  def parse_element(elem, allowed_range)
    values = elem.split(",").map do |subel|
      if subel =~ /^\*/
        step = subel.size > 1 ? subel[2..-1].to_i : 1
        stepped_range(allowed_range, step)
      else
        if m = subel.match(SUBELEMENT_REGEX)
          if m[5]? # with range
            stepped_range(m[1].to_i..m[3].to_i, m[5].to_i)
          elsif m[3]? # range without step
            stepped_range(m[1].to_i..m[3].to_i, 1)
          else # just a numeric
            [m[1].to_i]
          end
        else
          raise ArgumentError.new("Bad Vixie-style specification #{subel}")
        end
      end
    end.flatten.sort

    {Set.new(values), values, elem}
  end

  # protected

  # returns a list of days which do both match time_spec[:dom] or time_spec[:dow]
  private def interpolate_weekdays(year, month)
    @_interpolate_weekdays_cache["#{year}-#{month}"] ||= interpolate_weekdays_without_cache(year, month)
  end

  private def interpolate_weekdays_without_cache(year, month)
    t = Time.new(year, month, 1)
    valid_mday, _, mday_field = time_specs[:dom]
    valid_wday, _, wday_field = time_specs[:dow]

    # Careful, if both DOW and DOM fields are non-wildcard,
    # then we only need to match *one* for cron to run the job:
    if !(mday_field == "*" && wday_field == "*")
      valid_mday = [] of Int32 if mday_field == "*"
      valid_wday = [] of Int32 if wday_field == "*"
    end

    # Careful: crontabs may use either 0 or 7 for Sunday:
    valid_wday << 0 if valid_wday.includes?(7)

    result = [] of Int32
    while t.month == month
      result << t.day if valid_mday.includes?(t.day) || valid_wday.includes?(t.day_of_week.to_i)
      t += 1.day
    end

    {Set.new(result), result}
  end

  private def nudge_year(t, dir = :next)
    t.year = t.year + (dir == :next ? 1 : -1)
  end

  private def nudge_month(t, dir = :next)
    spec = time_specs[:month][1]
    next_value = find_best_next(t.month, spec, dir)
    t.month = next_value || (dir == :next ? spec.first : spec.last)

    nudge_year(t, dir) if next_value.nil?

    # we changed the month, so its likely that the date is incorrect now
    valid_days = interpolate_weekdays(t.year, t.month)[1]
    t.day = dir == :next ? valid_days.first : valid_days.last
  end

  private def date_valid?(t, dir = :next)
    interpolate_weekdays(t.year, t.month)[0].includes?(t.day)
  end

  private def nudge_date(t, dir = :next, can_nudge_month = true)
    spec = interpolate_weekdays(t.year, t.month)[1]
    next_value = find_best_next(t.day, spec, dir)
    t.day = next_value || (dir == :next ? spec.first : spec.last)

    nudge_month(t, dir) if next_value.nil? && can_nudge_month
  end

  private def nudge_hour(t, dir = :next)
    spec = time_specs[:hour][1]
    next_value = find_best_next(t.hour, spec, dir)
    t.hour = next_value || (dir == :next ? spec.first : spec.last)

    nudge_date(t, dir) if next_value.nil?
  end

  private def nudge_minute(t, dir = :next)
    spec = time_specs[:minute][1]
    next_value = find_best_next(t.min, spec, dir)
    t.min = next_value || (dir == :next ? spec.first : spec.last)

    nudge_hour(t, dir) if next_value.nil?
  end

  private def time_specs
    @time_specs ||= begin
      # tokens now contains the 5 fields
      tokens = substitute_parse_symbols(@source).split(/\s+/)
      {
        :minute => parse_element(tokens[0], 0..59), # minute
        :hour   => parse_element(tokens[1], 0..23), # hour
        :dom    => parse_element(tokens[2], 1..31), # DOM
        :month  => parse_element(tokens[3], 1..12), # mon
        :dow    => parse_element(tokens[4], 0..6),  # DOW
      }
    end
  end

  private def substitute_parse_symbols(str)
    s = str.downcase
    SYMBOLS.each do |from, to|
      s = s.gsub(from, to)
    end
    s
  end

  private def stepped_range(rng, step = 1)
    len = rng.end - rng.begin

    num = len./(step)
    result = (0..num).map { |i| rng.begin + step * i }

    result.pop if result[-1] == rng.end && rng.exclusive?
    result
  end

  # returns the smallest element from allowed which is greater than current
  # returns nil if no matching value was found
  private def find_best_next(current, allowed, dir)
    if dir == :next
      allowed.sort.find { |val| val > current }
    else
      allowed.sort.reverse.find { |val| val < current }
    end
  end

  private def validate_source
    unless @source.responds_to?(:split)
      raise ArgumentError.new("not a valid cronline")
    end
    source_length = @source.split(/\s+/).size
    unless source_length >= 5 && source_length <= 6
      raise ArgumentError.new("not a valid cronline")
    end
  end
end
