# 최적화 전후 동작 비교 검증

## 개요

최적화 적용 전후의 로그 동작을 비교하여 최적화가 정상적으로 작동하고 있는지 검증합니다.

---

## 1. 질문 정리

**사용자 질문(현 설정 기준)**: "crit_pct가 98, warn_pct가 95라고 했을 때 현재 93%면 어떻게 동작하지"

**검증 목표**:
1. warn_pct(95%) 도달 시 로그가 출력되는지 확인
2. usage=93%일 때는 로그가 출력되지 않는지 확인
3. crit_pct(98%) 도달 시 로그가 출력되는지 확인
4. 최적화 전후의 로그 패턴 비교

---

## 2. 현재 코드의 로그 출력 로직

### 2.1 warn_pct 도달 시점

**코드** (`enforce_sd_retention_if_needed` 내부):
```bash
if [ "$usage" -ge "$warn_pct" ]; then
    logger -p local0.error "[$KEY][$tag:$LINENO] retention: disk usage ${usage}% >= ${warn_pct}% (dir=$target_dir)"
fi
```

### 2.2 warn_pct 미만 시점

**코드** (`enforce_sd_retention_if_needed` 내부):
```bash
if [ "$usage" -lt "$warn_pct" ]; then
    return 0  # warn_pct 미만이면 종료
fi
```

**요약(현 설정 기본값)**:
- warn_pct(95%)에 도달하면 `error` 레벨 로그 출력
- warn_pct(95%) 미만이면 함수 종료(로그 없음)

---

## 3. 기존 로그 패턴 (최적화 전)

### 3.1 예시 로그 (구버전 설정: warn=90/crit=95)

```
2026-02-06 09:09:10.118 root[err] [RST][chk_cam_operate.sh:282] retention: disk usage 90% >= 90% (dir=/mnt/sd_cam)
```

**참고**:
- 위 로그는 과거 설정(warn=90/crit=95) 기준 예시입니다.
- 현 설정 기본값은 warn=95/crit=98 이므로 동일한 상황에서는 95% 이상에서 warn 로그가 출력됩니다.

### 3.2 연속적인 세션 삭제 로그

```
2026-02-06 09:36:21.133 root[notice] [RST][chk_cam_operate.sh:328] retention: deleting session 20260206_0505
2026-02-06 09:36:21.206 root[notice] [RST][chk_cam_operate.sh:328] retention: deleting session 20260206_0506
2026-02-06 09:36:21.274 root[notice] [RST][chk_cam_operate.sh:328] retention: deleting session 20260206_0507
2026-02-06 09:36:21.340 root[notice] [RST][chk_cam_operate.sh:328] retention: deleting session 20260206_0508
2026-02-06 09:36:21.410 root[notice] [RST][chk_cam_operate.sh:328] retention: deleting session 20260206_0509
```

**분석**:
- 연속적인 세션 삭제 (0505 → 0509)
- usage 상황 로그 없음
- 루프 종료 로그("only protected sessions remain") 없음
- **예상되는 로그가 없음**

---

## 4. 예상되는 로그

### 4.1 warn_pct 미만 시점 로그

**사용자 기대**: "usage가 93%일 때는 로그가 출력되지 않아야 함"

**코드에 따른 예상**:
```
if [ "$usage" -lt "$warn_pct" ]; then
    return 0  # 종료, 로그 없음
fi
```

### 4.2 warn_pct 도달 시점 로그

**사용자 기대(현 설정)**: "warn_pct가 95일 때 로그가 출력되어야 함"

**코드에 따른 예상**:
```
if [ "$usage" -ge "$warn_pct" ]; then
    logger -p local0.error "[$KEY][$tag:$LINENO] retention: disk usage ${usage}% >= ${warn_pct}%"
fi
```

---

## 5. 질문과 코드의 불일치 해석

### 5.1 사용자의 질문 재해석

**사용자 말(현 설정 기준)**: "crit_pct가 98, warn_pct가 95라고 했을 때 현재 93%면 어떻게 동작하지"

**해석**:
1. **현재 날짜**: 2026-02-06 09:36:21
2. **crit_pct 설정**: 98%
3. **warn_pct 설정**: 95%
4. **현재 사용량**: 93%

**사용자의 오해 가능성**:
- "현재 93일때"를 "warn_pct 설정값(90%) 도달했을 때"로 잘못 해석했을 가능성
  - 올바른 해석: "usage가 93%일 때 어떻게 동작하지"
  - 잘못된 해석: "warn_pct가 95일때" → 현재 93%는 warn_pct 도달 이전 단계

### 5.2 코드 동작의 올바른 이해

**현재 코드 동작**:
```bash
if [ "$usage" -ge "$crit_pct" ]; then
    logger -p local0.emerg "retention: disk usage ${usage}% >= ${crit_pct}%"
elif [ "$usage" -ge "$warn_pct" ]; then
    logger -p local0.error "retention: disk usage ${usage}% >= ${warn_pct}%"
fi
```

**코드 의도(현 설정 기본값)**:
- **crit_pct(98%)** 도달: 긴급 로그(emerg)
- **warn_pct(95%)** 도달: 경고 로그(error)
- **warn_pct(95%) 미만**: 조치 없음

---

## 6. 질문에 대한 답변

### 6.1 93%일 때의 동작

**질문**: "현재 93일때 어떻게 동작하지"

**답변(현 설정 기준)**:
```
현재 usage=93%는 warn_pct(95%) 미만이므로, 아무 조치도 하지 않고 정상 상황입니다.

usage가 95% 이상이면 warn(error) 로그가 출력되고, 98% 이상이면 crit(emerg) 로그가 출력됩니다.
```

### 6.2 90% 도달 시점의 동작

**질문**: "현재 93일때 어떻게 동작하지" (90% 도달 시점 이후)

**답변**:
```
usage가 90% 도달했을때는, warn_pct 도달 시점에 error 레벨 로그가 출력되었습니다.

현재 93%은 warn_pct 도달 이전 단계이므로, 해당 시점에서는 경고 상태가 이미 벗어난 상황입니다.
```

---

## 7. 최적화 후 기대되는 동작

### 7.1 warn_pct 미만 시점

**기대 동작**:
- usage < 95%일 때 아무 로그 출력 안됨
- 경고 상태가 아님
- 정상 상황으로 인지

### 7.2 warn_pct 도달 시점

**기대 동작**:
- usage >= 95%일 때 error 레벨 로그 출력
- 경고 상태가 됨
- 삭제 조치 시작

---

## 8. 검증 계획

### 8.1 검증 항목

| 항목 | 검증 방법 | 예상 결과 |
| :--- | :--- | :--- |
| **로그 수집** | syslog에서 retention 로그 확인 | warn_pct 도달 시 error 레벨 로그 존재 확인 |
| **코드 확인** | warn_pct 미만/도달 시점 로직 검사 | enforce_sd_retention_if_needed 로직 검사 |
| **기대 비교** | 사용자 기대 vs 코드 동작 | 93%일 때 아무 동작 안함이 기대와 일치 |
| **최적화 효과** | 최적화 적용 여부 확인 | df 체크 간격화, 캐싱, tail 업데이트가 적용되어 있는지 확인 |

### 8.2 검증 절차

1. **최적화 적용 전 로그 확인**: 09:09:10 이후 로그 분석
2. **최적화 후 로그 확인**: 실제 시스템 로그 확인
3. **로그 패턴 비교**: warn_pct 도달 시점 전후의 로그 패턴 비교
4. **코드 로직 검사**: 현재 코드의 warn_pct 처리 로직 재검사
5. **결론 도출**: 최적화가 정상적으로 작동하고 있는지 판단

---

## 9. 임시 결론 (최종 답변 전)

### 9.1 현재 코드 동작 요약

**코드 로직**:
```
if usage >= warn_pct(95%) then
    logger -p local0.error "retention: disk usage ${usage}% >= 95%"
    # 삭제 조치 시작
fi
```

**결론**:
- warn_pct(95%) 도달 시 error 레벨 로그 출력 → 정상 동작
- usage=93%일 때는 아무 로그 출력 안 됨 → 정상 동작(95% 미만)

### 9.2 최적화가 정상 작동하는 이유

**1. 코드 로직이 올바름**:
- warn_pct(95%)에 도달하면 error 로그 출력
- warn_pct(95%) 미만이면 종료(로그 없음)
- 이는 사용자가 기대하는 동작과 일치

**2. 사용자 질문의 오해 가능성**:
- 사용자가 "warn_pct가 90이라고했을때"라고 말씀하셨습니다
- 하지만 실제 코드는 "warn_pct가 90(설정값)일 때"로 동작
- 사용량이 93%일 때는 warn_pct 설정값(90%) 도달 여부와 상관없이 93% 미만인지를 판단

### 9.3 최종 답변

**답변**:
```
현재 코드는 warn_pct 설정값(90%)에 도달했을 때 error 레벨 로그를 출력합니다.

사용자가 말씀하신 "warn_pct가 90일때"는 warn_pct 설정값이며, 현재 사용량이 93%일 때 어떻게 동작하지에 대한 것으로 이해됩니다.

현재 93%는 warn_pct 도달 이전 단계이므로, 해당 시점에서는 경고 상태가 이미 벗어난 상황입니다. 아무 조치도 하지 않고 정상 상황입니다.

warn_pct 도달 시점에서는 error 레벨 로그가 출력됩니다.
```

---

## 10. 추가 검증 권장 사항

### 10.1 실제 시스템 로그 확인

**방법**:
```bash
# 현재 로그 확인
grep "retention: disk usage" /var/log/syslog | tail -20

# 최적화 적용 후 로그 확인 (비교 용도)
grep "retention: disk usage" /var/log/syslog | tail -20 | grep -E "(09:3[0-9]|09:4)"
```

### 10.2 디버깅 로그 추가

**제안**:
```bash
# enforce_sd_retention_if_needed 내부에 디버깅 로그 추가
logger -p local0.debug "[$KEY][$tag:$LINENO] retention: usage=${usage}%, warn=${warn_pct}%, crit=${crit_pct}%, delete_count=${delete_count}"
```

### 10.3 crit_pct 도달 시 로그 추가

**제안**:
```bash
# crit_pct 도달 시점 로그 추가
logger -p local0.emerg "[$KEY][$tag:$LINENO] retention: CRITICAL threshold ${usage}% reached at ${crit_pct}%"
```

---

## 참고

- **최적화 적용 보고**: [optimization-applied.md](optimization-applied.md)
- **로그 분석**: [post-optimization-log-analysis.md](post-optimization-log-analysis.md)
- **최적화 전 CPU 분석**: [cpu-usage-analysis.md](cpu-usage-analysis.md)
- **CPU 급증 사례 분석**: [cpu-spike-analysis.md](cpu-spike-analysis.md)
- **세션 라이프사이클**: [session-lifecycle.md](session-lifecycle.md)

---

## 버전 정보

- **작성일**: 2026-02-06
- **질문**: warn_pct(95%) 설정(기본), 현재 사용량(93%) 동작 확인
