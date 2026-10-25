/**
 * Conventional Commits rules for Vaulta.
 *
 * The merges into `master` are squash merges, so the title of the pull
 * request is the commit message that lands on the branch. The same rules
 * are applied in two places:
 *
 *   - locally, by the `commit-msg` hook of `lefthook.yml`;
 *   - in CI, by the "Conventional Commits title" job of Flutter CI, which
 *     validates the pull request title.
 *
 * release-please reads those commits to compute the next SemVer version and
 * to write the changelog, so a commit that does not follow the rules is
 * invisible to the release automation.
 *
 * https://www.conventionalcommits.org/en/v1.0.0/
 */
module.exports = {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // The type is the vocabulary release-please maps to the changelog
    // sections and to the SemVer bump, so it is a closed list.
    'type-enum': [
      2,
      'always',
      [
        'build',
        'chore',
        'ci',
        'docs',
        'feat',
        'fix',
        'perf',
        'refactor',
        'revert',
        'style',
        'test',
      ],
    ],
    // Lowercase type: `feat`, `fix`, `ci`.
    'type-case': [2, 'always', 'lower-case'],
    // The scope names the area of the change, in kebab-case:
    // `feat(security)`, `ci(deps)`.
    'scope-case': [2, 'always', 'kebab-case'],
    // A subject in lower case or in sentence case is fine ("add the vault"
    // and "Add the vault" are both accepted); Title Case and ALL CAPS are
    // not, because they read like a headline instead of a commit.
    'subject-case': [2, 'never', ['start-case', 'pascal-case', 'upper-case']],
    // No trailing period on the subject.
    'subject-full-stop': [2, 'never', '.'],
    // Pull request titles carry the issue context on top of the change, so
    // they are longer than the 100 characters commitlint allows by default.
    'header-max-length': [2, 'always', 120],
  },
};
