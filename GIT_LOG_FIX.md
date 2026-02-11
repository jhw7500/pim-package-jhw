# Git Log UTF-8 Display Fix

## Problem
Git log shows garbled Korean characters on target system.

## Cause
Target system locale is not set to UTF-8.

## Solution

### On Target System

1. **Check current locale:**
```bash
locale
echo $LANG
```

2. **Set UTF-8 locale:**
```bash
export LANG=ko_KR.UTF-8
export LC_ALL=ko_KR.UTF-8
```

3. **Make it permanent (add to ~/.bashrc or /etc/environment):**
```bash
echo 'export LANG=ko_KR.UTF-8' >> ~/.bashrc
echo 'export LC_ALL=ko_KR.UTF-8' >> ~/.bashrc
source ~/.bashrc
```

4. **Configure git to use UTF-8:**
```bash
git config --global i18n.logOutputEncoding utf-8
git config --global i18n.commitEncoding utf-8
```

5. **Verify:**
```bash
git log --oneline -3
```

## Alternative: View with --encoding

If you cannot change system locale:
```bash
git log --encoding=UTF-8
```

## Commit Messages Reference

For commits that appear garbled, here are the original messages:

### 90e2056 - chore: Update to version 0.5.8
```
버전 업데이트 및 스크립트 미세 조정

- Version: 0.5.7.2 → 0.5.8
- DEBIAN/control: 0.5.8 릴리즈 정보 추가
- 런타임 스크립트 최종 조정
```

English: Version update and script refinements

### c777a6d - Merge feat/vcm-update-4.3: v0.5.8 통합 업데이트
```
주요 업데이트:
- gstApp v1.2 → v1.4: 파이프라인 저지연 최적화, 오브젝트 풀링
- ORD v4.7 → v4.8.1: 보안 강화, 메모리 안전성, SD 카드 체크
- VCM v4.2 → v4.3: 비동기 파일 I/O, 녹화 동기화 개선
- MAX9296 v1.6 → v2.0: 커널 패닉 3건 수정
- 런타임 스크립트 강화: 설정 마이그레이션, 녹화 관리, 복구 전략
- RAW→BMP 병렬 변환 유틸리티 추가
- Docker 빌드 환경 구축

변경 규모:
- 총 140개 커밋 (gstApp 72 + ORD 27 + VCM 20 + MAX9296 3 + 통합 30)
- 보안 개선 28개, 스레드 안전성 8개, 성능 개선 14개
- 런타임 스크립트 10개 개선

자세한 내역:
- docs/RELEASE_NOTES.md: 전체 릴리즈 노트
- docs/CHANGELOG.md: 변경사항 목록
- docs/gstApp/: gstApp 상세 문서
- docs/max9296/: MAX9296 드라이버 문서
```

English:
- Major updates to gstApp, ORD, VCM, MAX9296
- 140 total commits with security, performance, and stability improvements
- See docs/RELEASE_NOTES.md for full details

### 165c687 - docs: 런타임 스크립트 개선사항 문서화
```
릴리즈 노트와 체인지로그에 런타임 스크립트의 주요 개선사항을 추가했습니다.
```

English: Document runtime script improvements in release notes

## Summary

All commit messages are properly UTF-8 encoded. The garbled display is due to terminal locale settings, not the git repository itself. Follow the solution steps above to fix the display issue.
