import os
from pathlib import Path
import re
import sqlite3
import subprocess
import time
from termcolor import colored, cprint

from slgit import SlGit

class Fixes:
    def __init__(self, git_linux: os.PathLike, git_kernel_source: os.PathLike,
                 git_stable_queue: os.PathLike, db_file: os.PathLike, cfm_db_file: os.PathLike):
        self.branch = None
        self.repo_linux = SlGit(git_linux)
        self.repo_ks = SlGit(git_kernel_source)
        self.repo_stableq = SlGit(git_stable_queue)

        db_file = Path(db_file)
        if not db_file.exists():
            raise RuntimeError(f"no DB at: {db_file}")

        self.db = sqlite3.connect(db_file)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA foreign_keys = ON;')

        self.cfm_db_file = Path(cfm_db_file)
        if not self.cfm_db_file.exists() or \
                self.cfm_db_file.stat().st_mtime < time.time() - (7 * 24 * 3600):
            print('Refreshing DB')
            result = subprocess.run(['suse-get-maintainers', '-ro', 'linus'])
            if result.returncode:
                raise RuntimeError(f"\"{' '.join(result.args)}\" failed with: {result.returncode}")
            print('')

        self.cfm_cursor = None
        self.deps = []
        self.confs = []

        self.re_ver = re.compile(r'Stable-([0-9.]+)$')
        self.re_dep_of = re.compile(r'Stable-dep-of:\s*([0-9a-f]+)')
        self.re_fixes = re.compile(r'(?:[Ff]ixes:|[Cc][Cc]:.*stable.*#)\s+([0-9a-fA-F]{6,})')

    def __del__(self):
        if hasattr(self, 'db'):
            self.db.close()

    def _gde(self, sha: str):
        try:
            res = self.repo_linux.oneline('describe', '--contains', '--exact-match', sha) or \
                colored(f"SHA {sha} not known", 'red');
            return res.split('~')[0]
        except subprocess.CalledProcessError:
            return "no tag yet";

    def overview(self, prgname: str):
        print(f"{'SUBSYS':>30} | {'PRODUCT':>20} | {'TODO':>4} | COMMAND")
        for row in self.db.execute('''SELECT COUNT(fixes.id) AS cnt, branch.branch, subsys.subsys
                    FROM fixes
                        JOIN branch ON fixes.branch = branch.id
                        JOIN subsys ON fixes.subsys = subsys.id
                    WHERE done = 0
                    GROUP BY fixes.branch, fixes.subsys
                    HAVING cnt > 0
                    ORDER BY subsys.subsys, branch.branch;'''):
            print(f"{row['subsys']:>30} | {row['branch']:>20} | {row['cnt']:>4} | {prgname}",
                  f"'{row['subsys']}' '{row['branch']}'")

    def _get_fixes(self, subsys: str):
        return self.db.execute('''SELECT fixes.id, shas.sha, via.via
                   FROM fixes
                   LEFT JOIN via ON fixes.via = via.id
                   LEFT JOIN shas ON fixes.sha = shas.id
                   WHERE fixes.subsys = (SELECT id FROM subsys WHERE subsys = :subsys) AND
                       fixes.branch = (SELECT id FROM branch WHERE branch = :branch) AND
                       done = 0
                   ORDER BY fixes.id;''', { 'subsys': subsys, 'branch': self.branch })

    def oneline(self, subsys: str, branch: str):
        self.branch = branch
        for row in self._get_fixes(subsys):
            self.repo_linux.call('show', '--color', '--oneline', '-s', row['sha'])

    def _match_blacklist(self, sha: str):
        for fileStr in self.repo_linux.multiline('show', '--pretty=format:', '--name-only', sha):
            file = Path(fileStr)
            self.cfm_cursor.execute('''SELECT config.config, arch.arch, flavor.flavor, cbmap.value
                    FROM conf_file_map AS cfmap
                    LEFT JOIN config ON cfmap.config = config.id
                    LEFT JOIN conf_branch_map AS cbmap ON config.id = cbmap.config AND
                        cfmap.branch = cbmap.branch
                    LEFT JOIN arch ON cbmap.arch = arch.id
                    LEFT JOIN flavor ON cbmap.flavor = flavor.id
                    WHERE cfmap.branch = (SELECT id FROM branch WHERE branch = :branch)
                        AND cfmap.file = (SELECT id FROM file WHERE file = :file
                        AND dir = (SELECT id FROM dir WHERE dir = :dir))
                    ORDER BY 2,3,4,1;''',
                               { 'branch': self.branch,
                                 'file': str(file.name),
                                 'dir': str(file.parent) })

            for row in self.cfm_cursor:
                self.confs.append(row['arch'] + '/' + row['flavor'] + ':' + row['config'] + '=' +
                                  row['value'])

    # this is handled by tracking-fixes already, IMO
    #        #config = [ row[0] for row in cfm_cursor ]
    #        config = []
    #
    #        file_match = None
    #        if len(config):
    #            pass
    #
    #		# only some of the files match -- don't skip
    #        if not match is None and file_match is None:
    #            return None
    #
    #        match = file_match
    #
    #        print(f"{file=} {file.name=} {file.parent=} {config=}")
    #
    #		if (@config) {
    #			try {
    #				push @{$confs}, map { s/^[^:]+://; $_ }
    #					$repo_ks->command('grep', '-E', $config[0] . '=', "origin/$branch",
    #					'--', 'config');
    #			} catch ($e) {
    #				my $eq_n = $config[0] . '=n';
    #				# matches different bl entries -- suspicious
    #				return undef if (defined $file_match && $file_match ne $eq_n);
    #				$file_match = $eq_n;
    #			}
    #		}

    def _check_deps(self, sha: str, via: str):
        if via is None:
            return None

        m = self.re_ver.search(via)
        if not m:
            return None

        stable_ver = m.group(1)
        try:
            patches = self.repo_stableq.multiline('grep', '-l', sha, '--', f"queue-{stable_ver}/",
                           f"releases/{stable_ver}.*")
            self.deps = self.repo_stableq.multiline('grep', '-h', 'Stable-dep-of', '--', *patches)
        except subprocess.CalledProcessError:
            return None

        m = self.re_dep_of.search(self.deps[0])
        if not m:
            return None

        dep = m.group(1)
        row = self.db.execute('''SELECT 1
                        FROM fixes
                        WHERE sha = (SELECT id FROM shas WHERE sha LIKE :sha) AND
                            branch = (SELECT id FROM branch WHERE branch = :branch);''',
                       { 'sha': f'{dep}%', 'branch': self.branch }).fetchone()
        if not row:
            try:
                self.repo_ks.call('grep', dep, f"origin/{self.branch}", '--', 'patches.suse/',
                             'blacklist.conf');
            except subprocess.CalledProcessError:
                return f"Stable-dep-of: {dep} not included";

        return None

    def _should_blacklist(self, sha: str, via: str):
        self._match_blacklist(sha)

        return self._check_deps(sha, via)

    def _full_one(self, row: tuple):
        sha = row['sha']
        via = row['via']

        subprocess.run(['clear'])

        try:
            sha = self.repo_linux.oneline('rev-parse', sha)
        except subprocess.CalledProcessError as ex:
            raise RuntimeError(f"cannot find sha '{sha}' in your tree at {self.repo_linux.tree}") from ex

        self.confs = []
        self.deps = []
        match = self._should_blacklist(sha, via)
        if not match is None:
            cprint("blacklist:", 'light_green')
            print(sha, '#', match)
        else:
            self.repo_linux.call('show', '--color', sha)
            if len(self.confs):
                cprint("Configs:", 'light_green')
                for conf in self.confs:
                    print("\t", conf)
            print(colored('Present in:', 'light_green'), self._gde(sha))
            for fix in self.repo_linux.multiline('show', '--pretty=format:%b', '-s', sha):
                m = self.re_fixes.search(fix)
                if not m:
                    continue
                print(colored('Fixes:', 'light_green'), fix, f"({self._gde(fix)}):")
                print(f"git grep {fix}")

            if not via is None:
                print(colored('VIA:', 'light_green'), via)
                for dep in self.deps:
                    print("\t", dep)
            cprint("blacklist:", 'light_green')
            print(sha, "# ")
            print(colored('susegen', 'light_green'), "-r 'git-fixes' ~ -1", sha)
            print(colored('exportpatch', 'light_green'), "-fwsnd ~ -F 'git-fixes'", sha)

        done = input(colored('Mark as done? [y/N/q] ', 'light_red', attrs=["bold"])).strip().upper()
        if done == 'Q':
            return False

        if done == 'Y':
            self.db.execute('UPDATE fixes SET done = 1 WHERE id = :id', { 'id': row['id'] });
            self.db.commit()

        return True

    def full(self, subsys: str, branch: str):
        self.branch = branch
        with sqlite3.connect(f"file:{self.cfm_db_file}?mode=ro", uri=True) as cfm_db:
            cfm_db.row_factory = sqlite3.Row
            cfm_db.execute('PRAGMA foreign_keys = ON;')
            self.cfm_cursor = cfm_db.cursor()
            for row in self._get_fixes(subsys):
                if not self._full_one(row):
                    break
