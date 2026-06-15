# Workipedia Infra

Workipedia 운영 환경을 서버별 Docker Compose로 관리한다.

- BE 서버: Backend, MariaDB, Redis, Elasticsearch
- AI 서버: AI API, Qdrant, Ollama
- Frontend: Vercel에서 별도 배포

비즈니스 로직, DB migration과 API 계약은 각 애플리케이션 레포가 소유한다. 이 레포는 이미지 버전, 컨테이너 연결, 영속 볼륨과 런타임 환경만 관리한다.

## 구조

```text
.
├── be/
│   └── docker-compose.yml
├── ai/
│   └── docker-compose.yml
└── .github/workflows/validate.yml
```

각 서버에 해당 디렉토리와 실제 `.env`를 배치한다. 운영 환경값과 비밀값은 Git에 저장하지 않고 서버 배포 절차나 외부 Secret 저장소에서 관리한다.

## BE 서버

```bash
cd be
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

Backend는 `127.0.0.1:8080`에만 바인딩한다. 호스트의 Nginx 또는 기존 리버스 프록시가 `api.workipedia.wiki` 요청을 이 포트로 전달한다.
BE가 다른 물리 서버의 AI를 호출하므로 운영 환경에는 AI 서버의 실제 HTTPS 주소를 주입한다.

## AI 서버

```bash
cd ai
docker compose config
docker compose pull
docker compose up -d
docker compose ps
```

AI API는 `127.0.0.1:8000`에만 바인딩한다. Qdrant와 Ollama는 Docker 내부 네트워크에서만 접근한다.

로컬 provider를 사용하면 최초 실행 시 `ollama-init`이 채팅·임베딩 모델을 내려받는다. Cross-Encoder 모델 캐시는 `huggingface-cache` 볼륨에 보존한다.

AI의 Tool Calling을 BE 연동 모드로 운영할 때는 BE 서버 주소와 연동 모드를 운영 환경에 주입한다.

## 이미지 배포

각 애플리케이션 레포가 자신의 이미지를 빌드해 GHCR에 push한다.

```text
ghcr.io/beyond-sw-camp/be25-fin-wip-workipedia-be:<commit-sha>
ghcr.io/beyond-sw-camp/be25-fin-wip-workipedia-ai:<commit-sha>
```

운영 `.env`의 `BACKEND_IMAGE`, `AI_IMAGE`를 해당 SHA 태그로 갱신한 뒤 각 서버에서 `docker compose pull && docker compose up -d`를 실행한다. 운영에서는 변경 가능한 `latest`보다 commit SHA 태그를 권장한다.

## 기존 볼륨 연결

Compose 프로젝트가 바뀌면 같은 데이터라도 새 볼륨이 생성될 수 있다. 전환 전에 각 서버에서 실제 이름을 확인한다.

```bash
docker volume ls
```

확인한 실제 볼륨 이름을 서버의 `.env`에 지정한다. 마이그레이션 중에는 `docker compose down -v`를 실행하지 않는다.

## 네트워크 원칙

- MariaDB, Redis, Elasticsearch, Qdrant, Ollama 포트는 외부에 공개하지 않는다.
- BE와 AI API는 localhost에 바인딩하고 리버스 프록시를 통해서만 노출한다.
- AI 도메인은 방화벽, VPN 또는 프록시 접근 제어로 BE 서버만 호출할 수 있게 제한한다.
- 실제 secret과 운영 `.env`는 커밋하지 않는다.

## 구성 검증

PR과 `main`, `dev` 브랜치 변경 시 GitHub Actions가 비밀값이 아닌 임시값으로 두 Compose 파일의 문법과 변수 해석만 검증한다.

## 상태 확인

```bash
curl -fsS http://127.0.0.1:8080/actuator/health
curl -fsS http://127.0.0.1:8000/health
```

장애 확인:

```bash
docker compose ps
docker compose logs --tail=200 backend
docker compose logs --tail=200 ai
```
