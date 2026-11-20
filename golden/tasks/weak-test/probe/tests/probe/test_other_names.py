import sys; sys.path.insert(0, ".")
from contacts import full_name

assert full_name("Ada", "B", "Lovelace") == "Ada B Lovelace"
assert full_name("", "", "Lovelace") == "Lovelace"
