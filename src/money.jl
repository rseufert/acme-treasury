# Money is whole minor units everywhere but the wire, as it is in mock-bank.

"""
    cents("29496.200") == 2949620

Minor units from a decimal string, exactly. SAP writes three decimals for a
two-decimal currency; a third decimal that is not zero is refused rather than
rounded, because a forecast that is a cent out never reconciles.
"""
function cents(text::AbstractString)::Int
    m = match(r"^\s*([+-]?)(\d+)(?:\.(\d+))?\s*$", text)
    m === nothing && throw(ArgumentError("not an amount: $(repr(text))"))
    fraction = rpad(something(m[3], ""), 2, '0')
    all(==('0'), fraction[3:end]) ||
        throw(ArgumentError("more than two decimals in $(repr(text))"))
    value = parse(Int, m[2]) * 100 + parse(Int, fraction[1:2])
    m[1] == "-" ? -value : value
end

"""
    money(-12380050) == "-123,800.50"
"""
function money(minor::Integer)::String
    whole, fraction = divrem(abs(minor), 100)
    digits = replace(string(whole), r"(?<=\d)(?=(\d{3})+$)" => ",")
    string(minor < 0 ? "-" : "", digits, ".", lpad(fraction, 2, '0'))
end
