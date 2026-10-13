return {
  name = 'asyncapi-cli',
  description = 'The AsyncAPI CLI: validate, diff and generate AsyncAPI documents.',
  homepage = 'https://www.asyncapi.com/tools/cli',
  licenses = {
    'Apache-2.0',
  },
  languages = {
    'AsyncAPI',
  },
  categories = {
    'Linter',
  },
  source = {
    id = 'pkg:npm/%40asyncapi/cli@6.2.0',
  },
  bin = {
    asyncapi = 'npm:asyncapi',
  },
}
