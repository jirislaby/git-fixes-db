import os
import subprocess

class SlGit:
    def __init__(self, tree: os.PathLike):
        self.tree = tree

    def call(self, *args, **kwargs):
        cmd = ['git', '-C', str(self.tree), *args]
        return subprocess.run(cmd, check=True, text=True, **kwargs)

    def oneline(self, *args):
        res = self.call(*args, capture_output=True)
        return res.stdout.rstrip()

    def multiline(self, *args):
        res = self.call(*args, capture_output=True)
        return res.stdout.splitlines()
