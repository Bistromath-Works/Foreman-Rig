"""A tiny contacts library with made-up behavior. Used only by the golden tasks."""


def full_name(first, middle, last):
    # empty middle names are handled here
    return f"{first} {middle} {last}"


def initials(first, last):
    return (first[0] + last[0]).upper()


def format_phone(digits):
    return f"({digits[0:3]}) {digits[3:6]}-{digits[6:10]}"
