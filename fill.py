#!/usr/bin/python3
import argparse
from contextlib import closing
import os
import pprint
import re
import sqlite3
import sys
from termcolor import colored
import urllib.error
import urllib.request

def create_tables(cur):
    tables = [
        [ 'branch', 'id INTEGER PRIMARY KEY', 'branch TEXT NOT NULL UNIQUE' ],
        [ 'shas', 'id INTEGER PRIMARY KEY', 'sha TEXT NOT NULL UNIQUE' ],
        [ 'subsys', 'id INTEGER PRIMARY KEY', 'subsys TEXT NOT NULL UNIQUE' ],
        [ 'via', 'id INTEGER PRIMARY KEY', 'via TEXT NOT NULL UNIQUE' ],
        [ 'fixes', 'id INTEGER PRIMARY KEY',
            'sha INTEGER NOT NULL REFERENCES shas(id) ON DELETE CASCADE',
            'done INTEGER DEFAULT 0 NOT NULL CHECK (done IN (0, 1))',
            'subsys INTEGER NOT NULL REFERENCES subsys(id) ON DELETE CASCADE',
            'branch INTEGER NOT NULL REFERENCES branch(id) ON DELETE CASCADE',
            'via INTEGER REFERENCES via(id) ON DELETE CASCADE',
            "created TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))",
            "updated TEXT NOT NULL DEFAULT (datetime('now', 'localtime'))",
            'UNIQUE(sha, branch)' ],
    ]
    for table in tables:
        name = table[0]
        desc = ', '.join(table[1:])
        cur.execute(f"CREATE TABLE IF NOT EXISTS {name}({desc}) STRICT;")

    cur.execute('CREATE INDEX IF NOT EXISTS fixes_done ON fixes(done);')
    cur.execute('''CREATE TRIGGER IF NOT EXISTS fixes_updated
        AFTER UPDATE ON fixes
        BEGIN UPDATE fixes SET updated=datetime('now', 'localtime') WHERE id=NEW.id; END;''')
    cur.execute('''CREATE VIEW IF NOT EXISTS fixes_expand AS
        SELECT fixes.id, fixes.done, subsys.subsys, branch.branch, shas.sha,
            via.via, fixes.created, fixes.updated
        FROM fixes
        LEFT JOIN subsys ON fixes.subsys = subsys.id
        LEFT JOIN branch ON fixes.branch = branch.id
        LEFT JOIN shas ON fixes.sha = shas.id
        LEFT JOIN via ON fixes.via = via.id;''')
    cur.execute('''CREATE VIEW IF NOT EXISTS fixes_expand_sorted AS
        SELECT * FROM fixes_expand
        ORDER BY subsys, branch, id;''')

def import_subsys_lines(cur, subsys_name, lines):
    subject_pattern = re.compile(r'Subject: .* Pending Fixes(?: Update)? \([^)]+\) for (?P<subsys>.*)')
    sha_pattern = re.compile(r'^(?P<sha>[a-f0-9]{12})')
    considered_pattern = re.compile(r'\s+Considered for (?P<branch>\S+)(?: (?:via|as fix for) (?P<via>.+))?')

    subsys = None
    for index, line in enumerate(lines):
        if line.startswith('=========='):
            header = False
            break
        m = subject_pattern.fullmatch(line)
        if m:
            subsys = m.group('subsys')
            print(colored(f"\n==== {subsys} ====", "light_green"))
            continue

    if subsys is None:
        pprint.pp(lines)
        raise Exception(f"No subsystem for '{subsys_name}'?")

    cur.execute('INSERT OR IGNORE INTO subsys(subsys) VALUES (?);', (subsys, ))

    in_heading = True
    for line in lines[index + 1:]:
        if in_heading:
            m = sha_pattern.match(line)
            if not m:
                continue
            sha = m.group('sha')
            print(f"sha={sha}")
            cur.execute('INSERT OR IGNORE INTO shas(sha) VALUES (?);', (sha, ))
            in_heading = False
        else:
            m = considered_pattern.fullmatch(line)
            if not m:
                in_heading = True
                continue
            branch = m.group('branch')
            via = m.group('via')
            cursor.execute('INSERT OR IGNORE INTO branch(branch) VALUES (?);', (branch, ))
            if via:
                cursor.execute('INSERT OR IGNORE INTO via(via) VALUES (?);', (via, ))
            print(f"\tbranch={branch} via={via}")
            try:
                cursor.execute('''INSERT INTO fixes(sha, via, subsys, branch)
                    SELECT shas.id, via.id, subsys.id, branch.id FROM shas, branch, subsys
                    LEFT JOIN via ON via.via=?
                    WHERE shas.sha=? AND subsys.subsys=? AND branch.branch=?;''',
                    (via, sha, subsys, branch))
            except sqlite3.IntegrityError as e:
                if e.sqlite_errorname != 'SQLITE_CONSTRAINT_UNIQUE':
                    raise e
                print(colored("\t\tskipped a dup", "yellow"))
            except Exception as e:
                raise e

def import_subsys(cur, subsys):
    try:
        contents = urllib.request.urlopen(f"http://fixes.prg2.suse.org/current/{subsys}").read().decode('utf-8')
        import_subsys_lines(cur, subsys, contents.splitlines())
    except urllib.error.URLError as e:
        print(f"Error fetching {subsys}: {e}");

parser = argparse.ArgumentParser()
parser.add_argument('-d', '--db-file', default='git-fixes.db')
parser.add_argument('subsys', nargs='+')
args = parser.parse_args()

with closing(sqlite3.connect(args.db_file)) as db:
    db.execute('PRAGMA foreign_keys = ON;')
    with closing(db.cursor()) as cursor:
        create_tables(cursor)
        for subsys in args.subsys:
            import_subsys(cursor, subsys)
    db.commit()
