"""
The days the bank settles on: weekdays that are not on its holiday list.
"""
struct BankCalendar
    holidays::Set{Date}
end
BankCalendar() = BankCalendar(Set{Date}())

isbusinessday(cal::BankCalendar, day::Date) = dayofweek(day) <= 5 && !(day in cal.holidays)

"The first business day on or after `day`."
function onorafter(cal::BankCalendar, day::Date)::Date
    while !isbusinessday(cal, day)
        day += Day(1)
    end
    day
end

"`n` business days after `day`; `n == 0` is `onorafter`."
function addbusinessdays(cal::BankCalendar, day::Date, n::Integer)::Date
    day = onorafter(cal, day)
    for _ in 1:n
        day = onorafter(cal, day + Day(1))
    end
    day
end
