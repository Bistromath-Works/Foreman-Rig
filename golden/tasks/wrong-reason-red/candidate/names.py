def join_names(*parts):
    return " ".join(p.strip() for p in parts if p.strip())
