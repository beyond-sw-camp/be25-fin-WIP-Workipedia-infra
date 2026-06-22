# Workipedia Infra

Workipedia 운영 인프라는 AWS 리소스와 서버별 Docker Compose로 관리한다. 애플리케이션 소스, 비즈니스 로직, DB migration, API 계약은 각 애플리케이션 레포가 소유하고, 이 레포는 배포 경계와 런타임 환경을 관리한다.

## AWS 운영 구조

```text
Cloudflare DNS
  -> CloudFront
       -> S3 FE Bucket
       -> /api/* -> ALB -> BE EC2 t3.large
                              -> RDS MariaDB
                              -> Redis container
                              -> Elasticsearch container
                              -> AI EC2 Auto Scaling Group
                                    -> Qdrant EC2
```

- FE: Vue build 결과물을 S3 FE Bucket에 업로드하고 CloudFront로 서비스한다.
- Upload 파일: FE 정적 파일과 분리된 별도 S3 Upload Bucket을 사용한다.
- BE: EC2 `t3.large`에서 Docker Compose로 Spring Boot, Redis, Elasticsearch를 실행한다.
- DB: 로컬 MariaDB 컨테이너를 사용하지 않고 RDS MariaDB endpoint를 사용한다.
- AI: EC2 Auto Scaling Group에서 Docker Compose로 FastAPI와 Ollama를 실행한다.
- Qdrant: AI 서버 내부가 아니라 별도 EC2에서 Docker Compose로 실행한다.
- DNS: Cloudflare DNS를 사용한다. Route 53은 사용하지 않는다.
- NAT Gateway: 사용하지 않는다. 필요한 outbound 접근은 퍼블릭 서브넷, VPC endpoint, 또는 운영 정책에 맞는 별도 방식을 사용한다.

## 디렉터리 구조

```text
.
├── be/
│   ├── docker-compose.yml
│   └── .env.example
├── ai/
│   ├── docker-compose.yml
│   └── .env.example
├── qdrant/
│   ├── docker-compose.yml
│   └── .env.example
├── legacy/
│   └── nginx/
├── scripts/
│   └── deploy.sh
└── .github/workflows/
    └── validate.yml
```

실제 `.env`와 secret 값은 Git에 저장하지 않는다. 서버에는 각 target 디렉터리의 `.env.example`을 참고해 `.env`를 직접 배치한다.

## 필요한 AWS 리소스

- S3 FE Bucket: Vue `dist/` 정적 파일 배포용
- CloudFront Distribution: 기본 origin은 S3 FE Bucket, `/api/*` behavior는 ALB origin
- S3 Upload Bucket: 사용자가 업로드한 파일 저장용
- ALB: CloudFront의 `/api/*` 요청을 BE EC2 `8080`으로 전달
- EC2 BE: `t3.large`, Docker Compose로 Spring Boot, Redis, Elasticsearch 실행
- RDS MariaDB: Spring datasource 대상
- EC2 Auto Scaling Group for AI: Docker Compose로 FastAPI와 Ollama 실행
- EC2 Qdrant: Docker Compose로 Qdrant 실행
- IAM User 또는 Role: FE 배포용 S3 업로드/CloudFront invalidation, BE 업로드 버킷 접근 권한

## FE 배포 책임

FE CI/CD는 `Workipedia-fe` 레포가 소유한다. FE 레포의 GitHub Actions가 `npm ci`, `npm run build`를 실행하고 `dist/`를 S3 FE Bucket에 동기화한다. `CLOUDFRONT_DISTRIBUTION_ID`가 설정되어 있으면 `/*` invalidation을 수행한다.

FE 레포에 필요한 GitHub Secrets:

```text
AWS_ACCESS_KEY
AWS_SECRET_KEY
AWS_REGION
S3_FE_BUCKET
CLOUDFRONT_DISTRIBUTION_ID
```

`CLOUDFRONT_DISTRIBUTION_ID`는 배포 직후 캐시 무효화가 필요할 때만 설정한다. infra 레포는 FE 정적 파일을 직접 빌드하거나 업로드하지 않는다.

## GitHub Secrets 배치

각 앱 레포가 자기 CI/CD를 실행한다. 따라서 secret은 실제 workflow가 실행되는 레포에 둔다.

| 레포 | 용도 | 필요한 Secrets |
| --- | --- | --- |
| `Workipedia-fe` | FE build 후 S3/CloudFront 배포 | `AWS_ACCESS_KEY`, `AWS_SECRET_KEY`, `AWS_REGION`, `S3_FE_BUCKET`, `CLOUDFRONT_DISTRIBUTION_ID` |
| `Workipedia-be` | BE image push 후 BE EC2 배포 | `DEPLOY_HOST`, `DEPLOY_PORT`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`, `GHCR_USERNAME`, `GHCR_PAT` |
| `Workipedia-ai` | AI image push 후 AI EC2 배포 | `DEPLOY_HOST`, `DEPLOY_PORT`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`, `GHCR_USERNAME`, `GHCR_PAT` |

BE 런타임의 S3 Upload Bucket 접근 권한은 GitHub Actions secret이 아니다. BE EC2 서버의 `be/.env`에 `AWS_ACCESS_KEY`, `AWS_SECRET_KEY`, `AWS_REGION`, `S3_UPLOAD_BUCKET`을 설정한다.

## BE 배포

BE EC2에는 `be/docker-compose.yml`과 `be/.env`를 배치한다.

```bash
./scripts/deploy.sh be
```

BE compose는 다음 컨테이너만 실행한다.

- `backend`: Spring Boot, `0.0.0.0:8080:8080` 바인딩
- `redis`: BE EC2 내부 Redis
- `elasticsearch`: BE EC2 내부 Elasticsearch. 워키 검색에서 `nori` analyzer를 쓰므로 `analysis-nori` 플러그인이 포함된 커스텀 이미지를 사용한다.

MariaDB, Cloudflare DDNS, Nginx, Certbot 컨테이너는 운영 compose에서 제거했다. Spring datasource는 RDS MariaDB를 가리키도록 `MARIADB_*` 환경변수로 구성한다.

BE 주요 환경변수:

```text
BACKEND_IMAGE
ELASTICSEARCH_IMAGE
MARIADB_HOST
MARIADB_PORT
MARIADB_DATABASE
MARIADB_USER
MARIADB_PASSWORD
REDIS_PASSWORD
JWT_SECRET
INTERNAL_API_KEY
AWS_ACCESS_KEY
AWS_SECRET_KEY
AWS_REGION
S3_UPLOAD_BUCKET
AI_BASE_URL
```

## AI 배포

AI EC2 또는 ASG launch template에는 `ai/docker-compose.yml`과 `ai/.env`를 배치한다.

```bash
./scripts/deploy.sh ai
```

AI compose는 FastAPI와 Ollama를 기본으로 실행하며 FastAPI는 `0.0.0.0:8000:8000`에 바인딩한다. 임베딩은 로컬 Ollama를 사용하고, FastAPI는 Docker 내부 DNS인 `http://ollama:11434`로 Ollama에 접근한다. Qdrant는 외부 EC2를 사용하므로 `QDRANT_HOST`, `QDRANT_PORT`를 환경변수로 받는다. BE가 AI에 접근할 수 있도록 AI 보안그룹에서 BE 보안그룹의 TCP `8000` 접근을 허용한다.

AI 주요 환경변수:

```text
AI_IMAGE
LLM_PROVIDER
EMBEDDING_PROVIDER
CHAT_MODEL
EMBEDDING_MODEL
OLLAMA_BASE_URL
OPENAI_API_KEY
GOOGLE_API_KEY
ANTHROPIC_API_KEY
QDRANT_HOST
QDRANT_PORT
TOOL_CLIENT
BE_BASE_URL
```

`EMBEDDING_PROVIDER=local`, `OLLAMA_BASE_URL=http://ollama:11434`를 기본값으로 사용한다. `ollama-init` 컨테이너가 `CHAT_MODEL`, `EMBEDDING_MODEL`을 pull하므로, 운영 배포 전에 모델 이름을 `.env`에서 확정한다.

## Qdrant 배포

Qdrant EC2에는 `qdrant/docker-compose.yml`과 `qdrant/.env`를 배치한다.

```bash
./scripts/deploy.sh qdrant
```

Qdrant는 `0.0.0.0:6333:6333`으로 바인딩하고 `qdrant-data` 볼륨을 유지한다. 운영에서는 보안그룹으로 BE/AI 보안그룹에서 오는 TCP `6333`만 허용하고, 인터넷 전체 공개는 금지한다.

## 보안그룹 규칙

권장 inbound 규칙:

| 대상 | 허용 소스 | 포트 | 목적 |
| --- | --- | --- | --- |
| CloudFront | Cloudflare DNS는 DNS만 담당 | 443 | 사용자 HTTPS 진입 |
| ALB | CloudFront origin-facing prefix list 또는 제한된 운영 소스 | 80/443 | `/api/*` origin |
| BE EC2 | ALB SG | 8080 | Spring Boot API |
| BE EC2 | 운영자 IP | 22 | SSH 운영 |
| AI ASG EC2 | BE SG | 8000 | BE -> AI 내부 호출 |
| Qdrant EC2 | BE SG, AI SG | 6333 | 벡터 저장소 접근 |
| RDS MariaDB | BE SG | 3306 | Spring datasource |

Redis와 Elasticsearch는 BE EC2 내부 Docker network에서만 사용하며 EC2 보안그룹 inbound로 열지 않는다.

## 이미지 배포

각 애플리케이션 레포가 자신의 이미지를 빌드해 GHCR에 push한다.

```text
ghcr.io/beyond-sw-camp/be25-fin-wip-workipedia-be:<commit-sha>
ghcr.io/beyond-sw-camp/be25-fin-wip-workipedia-be-elasticsearch:8.18.8
ghcr.io/beyond-sw-camp/be25-fin-wip-workipedia-ai:<commit-sha>
```

운영 `.env`의 `BACKEND_IMAGE`, `AI_IMAGE`를 SHA 태그로 갱신한 뒤 각 서버에서 배포 스크립트를 실행한다. 운영에서는 변경 가능한 `latest`보다 commit SHA 태그를 권장한다. `ELASTICSEARCH_IMAGE`는 BE 레포의 `docker/elasticsearch/Dockerfile`에서 빌드한 nori 포함 이미지를 사용한다.

## 구성 검증

PR과 `main`, `dev` 브랜치 변경 시 GitHub Actions가 `be`, `ai`, `qdrant` compose 파일의 문법과 변수 해석을 검증한다.

로컬 검증:

```bash
docker compose --env-file be/.env.example --file be/docker-compose.yml config --quiet
docker compose --env-file ai/.env.example --file ai/docker-compose.yml config --quiet
docker compose --env-file qdrant/.env.example --file qdrant/docker-compose.yml config --quiet
```

## Legacy

기존 홈서버, Nginx, Certbot, Cloudflare DDNS, Vercel 중심 배포는 현재 운영 기준이 아니다. 과거 참고용 Nginx 설정은 `legacy/nginx/`에만 보관한다.
