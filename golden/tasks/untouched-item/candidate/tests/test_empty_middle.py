import sys; sys.path.insert(0, ".")
from contacts import full_name

assert full_name("Ada", "", "Lovelace") == "Ada Lovelace", repr(full_name("Ada", "", "Lovelace"))
