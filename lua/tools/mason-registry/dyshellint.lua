return {
  name = 'dyshellint',
  description = 'My personal shell script linter',
  homepage = 'https://github.com/dynamotn/dyshellint',
  licenses = {
    'MIT',
  },
  languages = {
    'Bash',
  },
  categories = {
    'Linter',
  },
  source = {
    id = 'pkg:github/dynamotn/dyshellint@v1.1.0',
    asset = {
      {
        target = 'darwin_arm64',
        file = 'dyshellint_darwin_arm64.tar.gz',
        bin = 'dyshellint',
      },
      {
        target = 'darwin_x64',
        file = 'dyshellint_darwin_amd64.tar.gz',
        bin = 'dyshellint',
      },
      {
        target = 'linux_arm64',
        file = 'dyshellint_linux_arm64.tar.gz',
        bin = 'dyshellint',
      },
      {
        target = 'linux_x64',
        file = 'dyshellint_linux_amd64.tar.gz',
        bin = 'dyshellint',
      },
    },
  },
  bin = {
    dyshellint = '{{source.asset.bin}}',
  },
}
