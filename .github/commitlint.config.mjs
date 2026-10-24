export default {
  extends: ['@commitlint/config-conventional'],
  // Preserve already-reviewed history without rewriting its commit OIDs.
  ignores: [
    (message) => message === 'review-fix round 1',
    // #223 9421d83·08d5c9c: pre-PR Tribunal 이 심사한 커밋이다. 본문에 100자를 넘는 줄이 있다.
    (message) => [
      'fix(cam): PARTIAL 기동 뒤 파일검사 사다리가 module_reload 로 바로 오른다',
      'fix(cam): PARTIAL 월반은 schema 1 스냅샷만 읽고 health 계약의 예외로 남는다',
    ].includes(message.split('\n')[0]),
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
