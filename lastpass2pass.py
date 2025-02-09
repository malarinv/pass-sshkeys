#!/usr/bin/env python3

import argparse
import os
import re
import subprocess


class Record:
    def __init__(self, name, url, username, password, extra, grouping, fav):
        self.name_val = name
        self.url = url
        self.username = username
        self.password = password
        self.extra = extra
        self.grouping = grouping
        self.fav = fav

    @property
    def name(self):
        s = "lastpass/"
        if self.grouping:
            s += f"{self.grouping}/"
        if self.name_val:
            s += self.name_val
        s = s.replace(" ", "_").replace("'", "")
        return s

    def to_str(self):
        s = f"{self.password}\n---\n"
        if self.grouping:
            s += f"{self.grouping} / "
        if self.name_val:
            s += f"{self.name_val}\n"
        if self.username:
            s += f"username: {self.username}\n"
        if self.password:
            s += f"password: {self.password}\n"
        if self.url and self.url != "http://sn":
            s += f"url: {self.url}\n"
        if self.extra:
            s += f"{self.extra}\n"
        return s


def main():
    parser = argparse.ArgumentParser(description="Import LastPass CSV export into pass")
    parser.add_argument(
        "-f", "--force", action="store_true", help="Overwrite existing records"
    )
    parser.add_argument(
        "-d",
        "--default",
        metavar="GROUP",
        default="",
        help="Place uncategorised records into GROUP",
    )
    parser.add_argument("filename", help="Path to LastPass CSV file")
    args = parser.parse_args()

    print(f"Reading '{args.filename}'...")

    entries = []
    current_entry = []
    entry_pattern = re.compile(r"^(http|ftp|ssh)")

    try:
        with open(args.filename, "r") as f:
            for line in f:
                line = line.strip()
                if entry_pattern.match(line):
                    if current_entry:
                        entries.append("\n".join(current_entry))
                        current_entry = []
                current_entry.append(line)
            if current_entry:
                entries.append("\n".join(current_entry))
    except FileNotFoundError:
        print(f"Couldn't find {args.filename}!")
        return 1

    print(f"{len(entries)} records found!")

    records = []
    for entry in entries:
        parts = entry.split(",")
        url = parts[0]
        username = parts[1] if len(parts) > 1 else ""
        password = parts[2] if len(parts) > 2 else ""
        fav = parts[-1] if len(parts) > 6 else ""
        grouping = parts[-2] if len(parts) > 5 else args.default
        name = parts[-3] if len(parts) > 4 else ""
        extra = ",".join(parts[3:-4])[1:-1] if len(parts) > 7 else ""

        records.append(Record(name, url, username, password, extra, grouping, fav))

    print(f"Records parsed: {len(records)}")

    successful = 0
    errors = []
    for record in records:
        output_path = f"{record.name}.gpg"
        if os.path.exists(output_path) and not args.force:
            print(f"skipped {record.name}: already exists")
            continue

        print(f"Creating record {record.name}...", end="")
        try:
            proc = subprocess.Popen(
                ["pass", "insert", "-m", record.name], stdin=subprocess.PIPE, text=True
            )
            proc.communicate(input=record.to_str())
            if proc.returncode == 0:
                print(" done!")
                successful += 1
            else:
                print(" error!")
                errors.append(record)
        except Exception as e:
            print(f" error! ({str(e)})")
            errors.append(record)

    print(f"{successful} records successfully imported!")

    if errors:
        print(f"There were {len(errors)} errors:")
        error_names = [e.name for e in errors]
        print(", ".join(error_names) + ".")
        print(
            "These probably occurred because an identically-named record already existed, or because there were multiple entries with the same name in the csv file."
        )


if __name__ == "__main__":
    main()
