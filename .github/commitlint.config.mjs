export default {
  extends: ['@commitlint/config-conventional'],
  // Preserve already-reviewed history without rewriting its commit OIDs.
  ignores: [
    (message) => message === 'review-fix round 1',
    // #223 9421d83: pre-PR Tribunal 이 심사한 커밋이다. 본문 한 줄이 100자를 넘는다.
    (message) => message.split('\n')[0] ===
      'fix(cam): PARTIAL 기동 뒤 파일검사 사다리가 module_reload 로 바로 오른다',
  ],
  rules: {
    'header-max-length': [2, 'always', 100],
    'subject-empty': [2, 'never'],
    'type-empty': [2, 'never'],
    'type-enum': [2, 'always', [
      'feat', 'fix', 'chore', 'refactor', 'docs',
      'test', 'build', 'ci', 'perf', 'style'
    ]],
    // 한글 커밋 메시지 허용
    'subject-case': [0],
  },
};
