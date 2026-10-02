local function print_table(t, indent)
    if type(t) ~= "table" then print(tostring(t)) return end
    for k, v in pairs(t) do
        print(indent .. tostring(k) .. " = " .. type(v))
    end
end
