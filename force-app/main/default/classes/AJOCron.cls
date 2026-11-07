/**
 * Quartz-subset cron evaluator.
 *
 * Salesforce field order: Seconds Minutes Hours Day_of_month Month Day_of_week [Year]
 * Supported: * ? , - / and the JAN..DEC / SUN..SAT names.
 * Not supported: L W # — these throw rather than guessing.
 *
 * Every expression is evaluated in an explicit time zone, never in the running
 * user's: a schedule must not shift because a different user saved or ran it.
 * A blank zone means AJOConfig.defaultTimeZone() — the AJOSetting__c value if
 * set, otherwise the org's default time zone. DST transitions follow the
 * platform TimeZone rules for that zone.
 */
public with sharing class AJOCron {

    public class CronException extends Exception {}

    /**
     * Deprecated: no longer used as a fallback (it was one org's zone). Kept so
     * code referencing the constant still compiles. Use AJOConfig.defaultTimeZone().
     */
    public static final String DEFAULT_TZ = 'GMT';
    private static final Integer HORIZON_DAYS = 1500;

    private static final Map<String, Integer> MONTH_NAMES = new Map<String, Integer>{
        'JAN' => 1, 'FEB' => 2, 'MAR' => 3, 'APR' => 4,  'MAY' => 5,  'JUN' => 6,
        'JUL' => 7, 'AUG' => 8, 'SEP' => 9, 'OCT' => 10, 'NOV' => 11, 'DEC' => 12
    };
    private static final Map<String, Integer> DOW_NAMES = new Map<String, Integer>{
        'SUN' => 1, 'MON' => 2, 'TUE' => 3, 'WED' => 4, 'THU' => 5, 'FRI' => 6, 'SAT' => 7
    };

    // 1970-01-01 was a Thursday; cron numbers Sunday as 1, so Thursday is 5.
    private static final Date EPOCH = Date.newInstance(1970, 1, 1);

    public class Parsed {
        public List<Integer> seconds;
        public List<Integer> minutes;
        public List<Integer> hours;
        public Set<Integer> daysOfMonth;
        public Set<Integer> months;
        public Set<Integer> daysOfWeek;
        public Set<Integer> years;
        public Boolean domIsWildcard;
        public Boolean dowIsWildcard;
        public String raw;
    }

    // ---------------------------------------------------------------- parsing

    public static Parsed parse(String expr) {
        if (String.isBlank(expr)) {
            throw new CronException('Cron expression is blank.');
        }
        List<String> f = new List<String>();
        for (String part : expr.trim().toUpperCase().split('\\s+')) {
            if (String.isNotBlank(part)) { f.add(part); }
        }
        if (f.size() < 6 || f.size() > 7) {
            throw new CronException(
                'Expected 6 or 7 fields, found ' + f.size() + ' in: ' + expr);
        }
        for (String part : f) {
            // Strip the month and weekday names first: JUL contains an L and
            // WED contains a W, and neither is the Quartz special character.
            String probe = part;
            for (String nm : MONTH_NAMES.keySet()) { probe = probe.replace(nm, ''); }
            for (String nm : DOW_NAMES.keySet())   { probe = probe.replace(nm, ''); }
            if (probe.contains('#') || probe.contains('W') || probe.contains('L')) {
                throw new CronException(
                    'Unsupported cron character in "' + part
                    + '". L, W and # are not handled by this evaluator.');
            }
        }

        Parsed p = new Parsed();
        p.raw           = expr.trim();
        p.seconds       = sorted(expand(f[0], 0, 59, null));
        p.minutes       = sorted(expand(f[1], 0, 59, null));
        p.hours         = sorted(expand(f[2], 0, 23, null));
        p.daysOfMonth   = expand(f[3], 1, 31, null);
        p.months        = expand(f[4], 1, 12, MONTH_NAMES);
        p.daysOfWeek    = expand(f[5], 1, 7,  DOW_NAMES);
        p.years         = (f.size() == 7 && f[6] != '*' && f[6] != '?')
                          ? expand(f[6], 1970, 2200, null) : null;
        p.domIsWildcard = (f[3] == '*' || f[3] == '?');
        p.dowIsWildcard = (f[5] == '*' || f[5] == '?');
        return p;
    }

    private static Set<Integer> expand(String field, Integer lo, Integer hi,
                                       Map<String, Integer> names) {
        Set<Integer> out = new Set<Integer>();
        if (field == '*' || field == '?') {
            for (Integer i = lo; i <= hi; i++) { out.add(i); }
            return out;
        }
        for (String chunk : field.split(',')) {
            String part = chunk.trim();
            if (String.isBlank(part)) { continue; }

            Integer step = 1;
            Boolean hasStep = false;
            if (part.contains('/')) {
                hasStep = true;
                List<String> sp = part.split('/');
                part = sp[0].trim();
                try {
                    step = Integer.valueOf(sp[1].trim());
                } catch (Exception e) {
                    throw new CronException('Bad step value in "' + chunk + '".');
                }
                if (step < 1) { throw new CronException('Step must be positive: ' + chunk); }
            }

            Integer lowVal, highVal;
            if (part == '*' || part == '?' || part == '') {
                lowVal = lo; highVal = hi;
            } else if (part.contains('-')) {
                List<String> r = part.split('-');
                lowVal = token(r[0], names, lo, hi);
                highVal = token(r[1], names, lo, hi);
            } else {
                lowVal = token(part, names, lo, hi);
                // "1/1" and "5/10" both mean: start here and step to the end of
                // the range. Without hasStep, "1/1" collapses to day 1 only —
                // which is exactly what the production parity test caught.
                highVal = hasStep ? hi : lowVal;
            }

            if (lowVal > highVal) {
                // Wrapping range such as FRI-MON or 22-2.
                for (Integer i = lowVal; i <= hi; i += step) { out.add(i); }
                for (Integer i = lo; i <= highVal; i += step) { out.add(i); }
            } else {
                for (Integer i = lowVal; i <= highVal; i += step) { out.add(i); }
            }
        }
        if (out.isEmpty()) {
            throw new CronException('Field "' + field + '" matched no values.');
        }
        return out;
    }

    private static Integer token(String t, Map<String, Integer> names,
                                 Integer lo, Integer hi) {
        String s = t.trim();
        if (names != null && names.containsKey(s)) { return names.get(s); }
        Integer v;
        try {
            v = Integer.valueOf(s);
        } catch (Exception e) {
            throw new CronException('Cannot read "' + s + '" as a cron value.');
        }
        // Some authors write 0 for Sunday even though Salesforce numbers it 1.
        if (names == DOW_NAMES && v == 0) { return 1; }
        if (v < lo || v > hi) {
            throw new CronException(
                'Value ' + v + ' is outside the allowed range ' + lo + '-' + hi + '.');
        }
        return v;
    }

    private static List<Integer> sorted(Set<Integer> s) {
        List<Integer> l = new List<Integer>(s);
        l.sort();
        return l;
    }

    // ---------------------------------------------------------------- search

    public static Datetime next(String expr, Datetime after, String tzId) {
        return next(parse(expr), after, tzId);
    }

    public static Datetime next(Parsed p, Datetime after, String tzId) {
        TimeZone tz = TimeZone.getTimeZone(String.isBlank(tzId) ? AJOConfig.defaultTimeZone() : tzId);
        Datetime local = toLocalFields(after, tz);

        Date startDate = Date.newInstance(local.yearGmt(), local.monthGmt(), local.dayGmt());
        Integer afterHour = local.hourGmt();
        Integer afterMin  = local.minuteGmt();
        Integer afterSec  = local.secondGmt();

        Integer dowCursor = cronDayOfWeek(startDate);

        for (Integer dOff = 0; dOff < HORIZON_DAYS; dOff++) {
            Date d = startDate.addDays(dOff);
            Integer dow = ((dowCursor - 1 + dOff) < 0)
                          ? dowCursor
                          : Math.mod(dowCursor - 1 + dOff, 7) + 1;

            if (dayMatches(p, d, dow)) {
                for (Integer h : p.hours) {
                    if (dOff == 0 && h < afterHour) { continue; }
                    for (Integer mi : p.minutes) {
                        if (dOff == 0 && h == afterHour && mi < afterMin) { continue; }
                        for (Integer se : p.seconds) {
                            if (dOff == 0 && h == afterHour && mi == afterMin && se <= afterSec) { continue; }
                            return fromLocalFields(d, h, mi, se, tz);
                        }
                    }
                }
            }
        }
        return null;
    }

    public static List<Datetime> nextN(String expr, Datetime after, String tzId, Integer n) {
        Parsed p = parse(expr);
        List<Datetime> out = new List<Datetime>();
        Datetime cursor = after;
        for (Integer i = 0; i < n; i++) {
            Datetime nxt = next(p, cursor, tzId);
            if (nxt == null) { break; }
            out.add(nxt);
            cursor = nxt;
        }
        return out;
    }

    private static Boolean dayMatches(Parsed p, Date d, Integer dow) {
        if (!p.months.contains(d.month())) { return false; }
        if (p.years != null && !p.years.contains(d.year())) { return false; }

        // Quartz rule: whichever of day-of-month / day-of-week is not a wildcard
        // is the one that constrains. If both are constrained, either may match.
        Boolean domOk = p.daysOfMonth.contains(d.day());
        Boolean dowOk = p.daysOfWeek.contains(dow);

        if (p.domIsWildcard && p.dowIsWildcard) { return true; }
        if (p.domIsWildcard)  { return dowOk; }
        if (p.dowIsWildcard)  { return domOk; }
        return domOk || dowOk;
    }

    private static Integer cronDayOfWeek(Date d) {
        Integer n = EPOCH.daysBetween(d);
        return Math.mod(Math.mod(n + 4, 7) + 7, 7) + 1;
    }

    // ------------------------------------------------------------- time zone

    /** Returns a Datetime whose GMT accessors read as the local wall clock in tz. */
    @TestVisible
    private static Datetime toLocalFields(Datetime instant, TimeZone tz) {
        return instant.addSeconds(tz.getOffset(instant) / 1000);
    }

    /** Turns a local wall clock in tz back into a real instant. */
    @TestVisible
    private static Datetime fromLocalFields(Date d, Integer h, Integer mi,
                                            Integer se, TimeZone tz) {
        Datetime provisional = Datetime.newInstanceGmt(
            d.year(), d.month(), d.day(), h, mi, se);
        Integer off = tz.getOffset(provisional);
        Datetime actual = provisional.addSeconds(-off / 1000);
        Integer off2 = tz.getOffset(actual);
        if (off2 != off) {
            actual = provisional.addSeconds(-off2 / 1000);
        }
        return actual;
    }

    public static String formatLocal(Datetime instant, String tzId) {
        if (instant == null) { return ''; }
        return instant.format('yyyy-MM-dd HH:mm:ss',
                              String.isBlank(tzId) ? AJOConfig.defaultTimeZone() : tzId);
    }

    // ------------------------------------------------------------- describe

    /** Plain-English rendering for the console, so nobody has to read cron. */
    public static String describeSchedule(String expr) {
        Parsed p;
        try {
            p = parse(expr);
        } catch (Exception e) {
            return 'Invalid schedule';
        }
        Boolean everyHour = p.hours.size() == 24;
        Boolean everyMin  = p.minutes.size() == 60;

        if (everyHour && everyMin) { return 'Every minute'; }
        if (everyHour) { return everyHourText(p.minutes); }

        String whenText = 'at ' + clockTimes(p.hours, p.minutes);

        if (!p.domIsWildcard) {
            List<Integer> dl = sorted(p.daysOfMonth);
            if (dl.size() == 31) { return 'Daily ' + whenText; }
            List<String> ds = new List<String>();
            for (Integer d : dl) { ds.add(String.valueOf(d)); }
            return 'On day ' + String.join(ds, ', ') + ' of the month ' + whenText;
        }
        if (!p.dowIsWildcard) {
            if (p.daysOfWeek.size() == 7) { return 'Daily ' + whenText; }
            Map<Integer, String> lbl = new Map<Integer, String>{
                1 => 'Sun', 2 => 'Mon', 3 => 'Tue', 4 => 'Wed',
                5 => 'Thu', 6 => 'Fri', 7 => 'Sat'
            };
            List<String> ds = new List<String>();
            for (Integer d : sorted(p.daysOfWeek)) { ds.add(lbl.get(d)); }
            return String.join(ds, ', ') + ' ' + whenText;
        }
        return 'Daily ' + whenText;
    }

    /**
      * Describes a schedule that runs in every hour.
      *
      * This used to print p.minutes.size() as though it were the minute, so
      * '0 0,30 * * * ?' — a plain every-half-hour job — described itself as
      * "Every hour, at 2 minutes past", and a 0-30 range claimed minute 31.
      * The count of matching minutes is never the answer; the minutes are.
      */
    private static String everyHourText(List<Integer> minutes) {
        List<Integer> ms = ascending(minutes);
        if (ms.size() == 1) { return 'Every hour at :' + pad(ms[0]); }

        Integer step = evenStep(ms);
        if (step != null) {
            return ms[0] == 0
                   ? 'Every ' + step + ' minutes'
                   : 'Every ' + step + ' minutes from :' + pad(ms[0]);
        }
        if (isContiguous(ms)) {
            return 'Every minute from :' + pad(ms[0]) + ' to :' + pad(ms[ms.size() - 1]);
        }
        if (ms.size() <= 6) {
            List<String> parts = new List<String>();
            for (Integer m : ms) { parts.add(':' + pad(m)); }
            return 'Every hour at ' + String.join(parts, ', ');
        }
        return 'Every hour, at ' + ms.size() + ' different minutes';
    }

    /**
      * The gap, when the minutes form an even cadence around the clock face —
      * wrap included, so [0, 30] is every 30 minutes and [5, 35] is every 30
      * from :05. Null when they are not a cadence at all, like [0, 5, 30].
      */
    private static Integer evenStep(List<Integer> ms) {
        if (ms.size() < 2 || Math.mod(60, ms.size()) != 0) { return null; }
        Integer step = ms[1] - ms[0];
        if (step <= 0) { return null; }
        for (Integer i = 1; i < ms.size(); i++) {
            if (ms[i] - ms[i - 1] != step) { return null; }
        }
        if (60 - ms[ms.size() - 1] + ms[0] != step) { return null; }
        return step;
    }

    private static Boolean isContiguous(List<Integer> ms) {
        for (Integer i = 1; i < ms.size(); i++) {
            if (ms[i] - ms[i - 1] != 1) { return false; }
        }
        return true;
    }

    /** Every hour/minute pairing, so a second minute is not silently dropped. */
    private static String clockTimes(List<Integer> hours, List<Integer> minutes) {
        List<String> t = new List<String>();
        for (Integer h : ascending(hours)) {
            for (Integer m : ascending(minutes)) { t.add(pad(h) + ':' + pad(m)); }
        }
        if (t.size() == 1) { return t[0]; }
        if (t.size() <= 4) {
            String last = t.remove(t.size() - 1);
            return String.join(t, ', ') + ' and ' + last;
        }
        return t[0] + ', ' + t[1] + ' and ' + (t.size() - 2) + ' more';
    }

    private static List<Integer> ascending(List<Integer> source) {
        List<Integer> out = new List<Integer>(source);
        out.sort();
        return out;
    }

    private static String pad(Integer i) {
        return (i < 10 ? '0' : '') + String.valueOf(i);
    }
}