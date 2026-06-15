# Workipedia Infra

Workipedia 운영 환경을 서버별 Docker Compose로 관리한다.

- BE 서버: Backend, MariaDB, Redis, Elasticsearch
- AI 서버: AI API, Qdrant
- Frontend: Vercel에서 별도 배포

비즈니스 로직, DB migration과 API 계약은 각 애플리케이션 레포가 소유한다. 이 레포는 이미지 버전, 컨테이너 연결, 영속 볼륨과 런타임 환경만 관리한다.

## 구조

```text
.
├── be/
│   ├── docker-compose.yml
│   └── nginx/
│       ├── api.workipedia.wiki.conf
│       └── ai.workipedia.wiki.conf
├── ai/
│   └── docker-compose.yml
├── scripts/
│   └── deploy.sh
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

AI API는 AI 서버의 내부 주소 `192.168.0.162:8000`에 바인딩한다. Qdrant는 Docker 내부 네트워크에서만 접근한다. 기본 배포는 클라우드 LLM과 embedding provider를 사용하며, Cross-Encoder 모델 캐시는 `huggingface-cache` 볼륨에 보존한다.

AI의 Tool Calling을 BE 연동 모드로 운영할 때는 BE 서버 주소와 연동 모드를 운영 환경에 주입한다.

Ollama도 함께 실행하고 모델을 미리 내려받지만, 클라우드 provider를 사용하는 동안에는 추론에 사용하지 않는다. 로컬 전환이 필요할 때 서버의 provider 환경값만 변경해 다시 배포한다.

## 서버 배포

배포 서버에는 infra 레포와 해당 서버용 `.env`만 둔다. 애플리케이션 소스 레포는 필요하지 않다.

```bash
git pull
./scripts/deploy.sh be
```

AI 서버에서는 마지막 인자를 `ai`로 변경한다. 스크립트는 Compose 검증, GHCR 이미지 pull, 컨테이너 갱신과 상태 출력을 순서대로 수행한다.

비공개 GHCR 패키지를 처음 받는 서버에서는 패키지 읽기 권한이 있는 GitHub 토큰으로 먼저 로그인한다.

```bash
docker login ghcr.io
```

## Nginx와 HTTPS

공유기에서는 BE 서버로 TCP `80`, `443`만 전달한다. DB, Redis, Elasticsearch, Qdrant 포트는 외부에 열지 않는다.

`192.168.0.161` BE 서버를 외부 진입점으로 사용한다. 이 서버의 Nginx가 BE는 로컬 `8080`, AI는 내부망의 `192.168.0.162:8000`으로 전달한다.

```bash
sudo cp be/nginx/api.workipedia.wiki.conf /etc/nginx/sites-available/api.workipedia.wiki
sudo cp be/nginx/ai.workipedia.wiki.conf /etc/nginx/sites-available/ai.workipedia.wiki
sudo ln -s /etc/nginx/sites-available/api.workipedia.wiki /etc/nginx/sites-enabled/api.workipedia.wiki
sudo ln -s /etc/nginx/sites-available/ai.workipedia.wiki /etc/nginx/sites-enabled/ai.workipedia.wiki
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d api.workipedia.wiki -d ai.workipedia.wiki
```

두 도메인의 DNS는 인증서 발급 전에 같은 공인 IP를 가리켜야 한다. 공유기에서는 TCP `80`, `443`을 `192.168.0.161`로 포워딩하고, AI 서버의 `8000`은 외부에 포워딩하지 않는다.

## DDNS

BE Compose의 `cloudflare-ddns` 서비스가 공인 IPv4 변경을 감지해 다음 DNS 레코드를 자동 갱신한다.

```text
api.workipedia.wiki
ai.workipedia.wiki
```

Cloudflare에서 `Edit zone DNS` 템플릿으로 `workipedia.wiki` 전용 API Token을 생성하고 `.161` 서버의 `be/.env`에 저장한다.

```text
CLOUDFLARE_API_TOKEN=<Cloudflare API Token>
```

두 레코드는 SSH와 직접 HTTPS 연결에 사용하므로 Cloudflare DNS에서 `DNS only`로 설정한다. DDNS 상태는 다음 명령으로 확인한다.

```bash
docker compose logs --tail=100 cloudflare-ddns
```

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

- MariaDB, Redis, Elasticsearch, Qdrant 포트는 외부에 공개하지 않는다.
- BE API는 localhost에, AI API는 AI 서버의 내부 IP에 바인딩하고 BE 서버의 리버스 프록시를 통해 노출한다.
- AI 서버 방화벽은 `192.168.0.161`에서 오는 TCP `8000` 요청만 허용한다.
- AI 도메인은 방화벽, VPN 또는 프록시 접근 제어로 BE 서버만 호출할 수 있게 제한한다.
- 실제 secret과 운영 `.env`는 커밋하지 않는다.

## 구성 검증

PR과 `main`, `dev` 브랜치 변경 시 GitHub Actions가 비밀값이 아닌 임시값으로 두 Compose 파일의 문법과 변수 해석만 검증한다.

## 상태 확인

```bash
curl -fsS http://127.0.0.1:8080/actuator/health
curl -fsS http://192.168.0.162:8000/api/v1/health
```

장애 확인:

```bash
docker compose ps
docker compose logs --tail=200 backend
docker compose logs --tail=200 ai
```
