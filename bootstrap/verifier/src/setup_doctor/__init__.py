"""setup-doctor — verifies the one-time keyless-access setup for cluster-ctrl.

This package implements the FND-2 ("the setup is verified") requirement: a
programmatic check that confirms GitHub Actions can authenticate to a specific
Google Cloud project keylessly (via Workload Identity Federation) and that the
setup is correct and least-privilege.

It is designed to run with one code path in two places:
  * locally, with an operator's Application Default Credentials, and
  * inside GitHub Actions, with federated Workload Identity credentials.

See ``cli.py`` for the entry point and ``checks.py`` for the individual checks.
"""

__version__ = "0.1.0"
