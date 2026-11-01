# Debian packages of pg_fkpart

The script `build-deb.sh` builds one Debian package `postgresql-<N>-pg-fkpart` per
PostgreSQL major version `<N>`, from the current source tree. It automates the
manual procedure of the wiki page *How to create a debian package for pg_fkpart*.

It must run on a Debian or Ubuntu build server. Use the same distribution as the
target servers, because the dependencies of the packages are those of the build server.

## Requirements

- `devscripts` and `build-essential`, to build the packages
- `postgresql-common` and `postgresql-server-dev-all`, required by the
  `Build-Depends` field of `debian/control.in`
- `postgresql-server-dev-<N>` for each target PostgreSQL version `<N>`

The PostgreSQL server itself is not needed for the build.

The option `--install-deps` installs all of them with `apt` (it uses `sudo`):

```bash
packaging/build-deb.sh --install-deps --pg-versions "12 17 18"
```

The versions that are not in the distribution, for example PostgreSQL 18 on an
older Debian, come from the [PGDG repository](https://wiki.postgresql.org/wiki/Apt),
which must be configured first.

## Usage

```bash
git clone git@github.com:atsora/pg_fkpart.git
cd pg_fkpart
packaging/build-deb.sh --pg-versions "12 17 18"
```

Without `--pg-versions`, the packages are built for all the PostgreSQL versions whose
`pg_config` is installed in `/usr/lib/postgresql/<N>/bin/`.

The script does not need to run as root.

Options:

| Option | Description |
|--------|-------------|
| `-p`, `--pg-versions "V1 V2..."` | PostgreSQL major versions to build the packages for |
| `-n`, `--new-version VERSION` | Add a new entry to `debian/changelog` first, for example `1.8.0-1` |
| `-m`, `--message TEXT` | Description of the new changelog entry (with `--new-version`) |
| `-o`, `--output DIR` | Build directory, `build/` by default |
| `-d`, `--install-deps` | Install the required packages with `apt` |
| `-L`, `--no-lintian` | Do not run `lintian` after the build |
| `-h`, `--help` | Show the help |

## What the script does

1. Optionally installs the dependencies.
2. Determines the PostgreSQL versions and checks their `pg_config` is installed.
3. Optionally adds a new entry to `debian/changelog` with `dch`. The author is
   `DEBFULLNAME` / `DEBEMAIL`, or the git `user.name` / `user.email` by default.
4. Copies the source tree (without `.git`) to `build/pg-fkpart_<version>/pg-fkpart-<version>/`
   and creates the archive `pg-fkpart_<version>.orig.tar.gz` next to it, without the
   `debian` directory.
5. Generates `debian/control` from `debian/control.in` with `pg_buildext updatecontrol`,
   and checks it contains one package for each requested version.
6. Builds the packages with `debuild -us -uc` (unsigned).
7. Lists the created `.deb` files.

The packages are in `build/pg-fkpart_<version>/`:

```
build/pg-fkpart_1.7.0/postgresql-12-pg-fkpart_1.7.0-1_all.deb
build/pg-fkpart_1.7.0/postgresql-17-pg-fkpart_1.7.0-1_all.deb
build/pg-fkpart_1.7.0/postgresql-18-pg-fkpart_1.7.0-1_all.deb
```

The previous content of `build/pg-fkpart_<version>/` is removed at each run.

The build directory must be on a Linux file system that keeps the Unix permissions,
otherwise `dpkg-deb` fails with `control directory has bad permissions 777`. This is
the case of a Windows drive in WSL (`/mnt/c/...`), a CIFS share or a VirtualBox shared
folder. The script checks it, and in such a case the build directory must be moved
with `--output`, for example:

```bash
packaging/build-deb.sh -p "12 17 18" --output ~/pg_fkpart-build
```

## New version

When the extension changes:

1. Update `default_version` in `pg_fkpart.control`, add the new SQL scripts and list
   them in `DATA` in the `Makefile`.
2. Build with a new changelog entry:

   ```bash
   packaging/build-deb.sh -p "12 17 18" -n 1.8.0-1 -m "New feature xxx"
   ```

   To repackage the same extension version (for example for a new PostgreSQL version),
   increment only the Debian revision: `-n 1.7.0-2`.
3. Commit `debian/changelog`.

The script warns when `default_version` does not match the package version.

## Supported PostgreSQL versions

`pg_buildext` only builds for the versions that are both in `debian/pgversions`
(`all` here) and in the list returned by
`/usr/share/postgresql-common/supported-versions`. By default, this list is the
distribution default version only (or all the PGDG versions when the PGDG repository
is configured).

The script sets the environment variable `PG_SUPPORTED_VERSIONS` to the requested
versions, which overrides this list. So there is no need any more to edit
`/usr/share/postgresql-common/supported-versions` when the target version is not the
default one of the distribution.

## Install a package

```bash
sudo apt install ./postgresql-17-pg-fkpart_1.7.0-1_all.deb
```

Then in the database:

```sql
CREATE EXTENSION pg_fkpart;
-- or, after an upgrade of the package
ALTER EXTENSION pg_fkpart UPDATE;
```
