import sys; sys.path.insert(0, ".")
from names import join_names

assert join_names("Ada", "", "Lovelace") == "Ada Lovelace"
