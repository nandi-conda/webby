"""webby's checks, run the same way on a laptop, in GitHub Actions and on Dagger Cloud.

`dagger check` runs them all; `dagger check -l` lists them. See .dagger/README.md.
"""

from .main import WebbyCi as WebbyCi
