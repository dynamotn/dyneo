return {
  name = 'graphql-inspector',
  description = 'Compare GraphQL schemas, and say which change breaks a client.',
  homepage = 'https://the-guild.dev/graphql/inspector',
  licenses = {
    'MIT',
  },
  languages = {
    'GraphQL',
  },
  categories = {
    'Linter',
  },
  source = {
    id = 'pkg:npm/%40graphql-inspector/cli@7.0.0',
  },
  bin = {
    ['graphql-inspector'] = 'npm:graphql-inspector',
  },
}
