return {
  name = 'duckdb',
  description = 'An in-process SQL engine reading Parquet, CSV and JSON files',
  homepage = 'https://duckdb.org',
  licenses = {
    'MIT',
  },
  languages = {
    'SQL',
  },
  categories = {
    'Runtime',
  },
  source = {
    id = 'pkg:github/duckdb/duckdb@v1.5.6',
    asset = {
      {
        target = 'darwin_x64',
        file = 'duckdb_cli-osx-amd64.zip',
        bin = 'duckdb',
      },
      {
        target = 'darwin_arm64',
        file = 'duckdb_cli-osx-arm64.zip',
        bin = 'duckdb',
      },
      {
        target = 'linux_x64',
        file = 'duckdb_cli-linux-amd64.zip',
        bin = 'duckdb',
      },
      {
        target = 'linux_arm64',
        file = 'duckdb_cli-linux-arm64.zip',
        bin = 'duckdb',
      },
    },
  },
  bin = {
    duckdb = '{{source.asset.bin}}',
  },
}
