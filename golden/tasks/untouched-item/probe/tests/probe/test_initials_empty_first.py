import sys; sys.path.insert(0, ".")
from contacts import initials

assert initials("", "Lovelace") == "L"
