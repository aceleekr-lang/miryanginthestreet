# Supabase 설정 가이드 (가곡원류 명의, 약 15분)

## 1. 계정 생성 & Pro 결제
1. **supabase.com** 접속 → Start your project → 구글 계정으로 가입
2. Organization 생성 (이름: 가곡원류 등 아무거나)
3. Organization Settings > Billing → 카드 등록 → **Pro 플랜** 선택 ($25/월)
   - 11월 검수 마감 후: 데이터 이관·파기 → Free로 다운그레이드하면 과금 종료

## 2. 프로젝트 생성
1. New Project → 이름 `miryang-street`
2. Database Password: 아무 강한 암호 (메모해 두세요, 평소엔 안 씀)
3. Region: **Northeast Asia (Seoul)** ← 꼭 서울로
4. 생성 완료까지 1~2분 대기

## 3. 데이터베이스 만들기
1. 왼쪽 메뉴 **SQL Editor** → New query
2. `schema.sql` 파일 내용 **전체** 복사해 붙여넣기 → **Run**
3. "Success" 확인 (경고 몇 줄은 무시해도 됨)

## 4. 스토리지(사진 저장소) 만들기
1. 왼쪽 메뉴 **Storage** → New bucket
2. 이름: `evidence` / **Public bucket 체크 해제(비공개!)** → Create
   - ※ schema.sql에 스토리지 정책이 포함돼 있어서 버킷만 만들면 됩니다.
   - 만약 3번보다 버킷을 나중에 만들어 정책 에러가 났었다면, schema.sql 맨 아래
     `create policy evidence_...` 3줄만 다시 실행하세요.

## 5. 관리자 계정 만들기 (마스터 코드)
1. 왼쪽 메뉴 **Authentication** → Users → Add user → Create new user
2. Email: `admin@gagok.local` (실제 메일 아니어도 됨)
3. Password: **이것이 마스터 코드입니다.** 문자+숫자 8자 이상으로 정하고 안전하게 보관
4. "Auto Confirm User" 체크 → Create

## 6. 키 복사해서 코드에 꽂기
1. Settings(톱니) → **API**
2. `Project URL` 과 `anon public` 키 두 개 복사
3. `config.js` 파일을 열어 두 값을 교체

## 7. Vercel 배포
1. 폴더(index.html, config.js, merchants.csv, schema.sql 제외 가능, assets/) 그대로
   기존 방식대로 Vercel에 배포
2. 배포 주소 확인 → 저에게 알려주시면 QR 생성해 드립니다

## 체크리스트
- [ ] Pro 결제 완료
- [ ] 프로젝트 리전 = Seoul
- [ ] schema.sql 실행 성공
- [ ] evidence 버킷 (비공개) 생성
- [ ] 관리자 계정 + 마스터 코드 확정
- [ ] config.js에 URL·키 입력
- [ ] Vercel 배포 주소 확보

막히는 화면이 있으면 캡처해서 보내주세요.
