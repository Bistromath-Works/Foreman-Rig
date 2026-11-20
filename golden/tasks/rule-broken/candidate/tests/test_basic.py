import sys; sys.path.insert(0, ".")
from contacts import full_name, initials, format_phone

assert full_name("Ada", "B", "Lovelace") == "Ada B Lovelace"
assert initials("Ada", "Lovelace") == "AL"
