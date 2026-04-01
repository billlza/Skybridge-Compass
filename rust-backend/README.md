# Sinan Rust Backend

高性能 Rust 后端服务，用于替换 Supabase Edge Functions。

## 🚀 技术栈

- **Axum** - 现代异步 Web 框架
- **SQLx** - 编译时类型安全的 SQL 库
- **Tokio** - 异步运行时
- **Tower-HTTP** - HTTP 中间件（CORS、压缩、追踪）
- **Tracing** - 结构化日志和分布式追踪

## 📋 API 端点

所有端点与原 Supabase Edge Functions 保持一致：

| 方法 | 路径 | 描述 |
|------|------|------|
| GET | `/health` | 健康检查 |
| GET | `/get-user-profile` | 获取用户资料 |
| PUT | `/update-user-id` | 更新自定义用户ID |
| POST | `/check-user-id-availability` | 检查用户ID可用性 |
| POST | `/generate-nebula-id` | 生成星云ID |
| GET/POST | `/get-binding-status` | 获取绑定状态 |
| POST | `/send-verification-code` | 发送验证码 (v1) |
| POST | `/send-verification-code-v2` | 发送验证码 (v2) |
| POST | `/verify-code` | 验证验证码 |
| POST | `/bind-account` | 绑定账户 (v1) |
| POST | `/bind-account-v2` | 绑定账户 (v2) |
| POST | `/unbind-account` | 解绑账户 (v1) |
| POST | `/unbind-account-v2` | 解绑账户 (v2) |

## 🛠️ 开发环境设置

### 前置要求

- Rust 1.75+ (推荐使用 rustup 安装)
- PostgreSQL 数据库 (或 Supabase 项目)

### 安装步骤

1. **克隆并进入目录**
   ```bash
   cd rust-backend
   ```

2. **配置环境变量**
   ```bash
   cp .env.example .env
   # 编辑 .env 填入你的配置
   ```

3. **运行开发服务器**
   ```bash
   cargo run
   ```

4. **生产构建**
   ```bash
   cargo build --release
   ./target/release/sinan-backend
   ```

## 🔧 配置说明

| 环境变量 | 描述 | 默认值 |
|----------|------|--------|
| `HOST` | 服务器监听地址 | `0.0.0.0` |
| `PORT` | 服务器端口 | `3000` |
| `DATABASE_URL` | PostgreSQL 连接字符串 | 必填 |
| `SUPABASE_URL` | Supabase 项目 URL | 必填 |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase 服务密钥 | 必填 |
| `SUPABASE_ANON_KEY` | Supabase anon key | 必填 |
| `JWT_SECRET` | JWT 验证密钥 | 必填 |
| `PUBLIC_SITE_URL` | CLI 浏览器登录页基地址 | `https://skybridge.com` |
| `CLI_LOGIN_ENCRYPTION_KEY` | CLI 临时 token 包加密密钥，需为 32-byte base64url 或 64-char hex | 必填 |
| `CORS_ORIGINS` | 允许的跨域源 | `*` |
| `LOG_LEVEL` | 日志级别 | `info` |

### CLI 浏览器登录桥本地联调

如果你要本地验证 `/auth/cli` 和 `/api/cli-login/*`，推荐使用一套显式的本地配置，而不是混用线上默认值：

```bash
HOST=127.0.0.1
PORT=3110
DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:55432/postgres?sslmode=disable
SUPABASE_URL=https://<your-project-ref>.supabase.co
SUPABASE_ANON_KEY=<your-anon-key>
SUPABASE_SERVICE_ROLE_KEY=<your-service-role-key>
JWT_SECRET=<your-jwt-secret>
PUBLIC_SITE_URL=http://127.0.0.1:4173
CLI_LOGIN_ENCRYPTION_KEY=<32-byte-base64url-or-64-char-hex>
```

前端同时设置：

```bash
VITE_AUTH_API_BASE_URL=http://127.0.0.1:3110
```

如果你暂时拿不到线上 Postgres 的直连密码，也可以先把 migration 推到已 link 的 Supabase 项目，再在本地跑一个 Postgres 容器做 runtime 联调；CLI 登录桥只要求运行时 `DATABASE_URL` 可写，并不要求必须直连线上数据库。

## 🏗️ 项目结构

```
rust-backend/
├── Cargo.toml          # 依赖配置
├── .env.example        # 环境变量模板
├── README.md           # 项目文档
└── src/
    ├── main.rs         # 入口点和路由
    ├── config.rs       # 配置管理
    ├── state.rs        # 应用状态
    ├── error.rs        # 错误处理
    ├── auth.rs         # 认证逻辑
    ├── db.rs           # 数据库操作
    ├── models.rs       # 数据模型
    ├── utils.rs        # 工具函数
    └── handlers/       # 请求处理器
        ├── mod.rs
        ├── bind_account.rs
        ├── bind_account_v2.rs
        ├── check_user_id.rs
        ├── generate_nebula_id.rs
        ├── get_binding_status.rs
        ├── get_user_profile.rs
        ├── send_verification_code.rs
        ├── send_verification_code_v2.rs
        ├── unbind_account.rs
        ├── unbind_account_v2.rs
        ├── update_user_id.rs
        └── verify_code.rs
```

## 🔒 认证

所有 API 端点（除 `/health`）都需要 Bearer Token 认证：

```bash
curl -H "Authorization: Bearer YOUR_SUPABASE_JWT" \
     http://localhost:3000/get-user-profile
```

## 📈 性能优势

相比 Supabase Edge Functions (Deno):

- **更快的启动时间** - 编译为原生二进制
- **更低的内存占用** - Rust 的零成本抽象
- **更好的并发性能** - Tokio 异步运行时
- **编译时类型检查** - 减少运行时错误

## 🐳 Docker 部署

```dockerfile
FROM rust:1.75 as builder
WORKDIR /app
COPY . .
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/sinan-backend /usr/local/bin/
EXPOSE 3000
CMD ["sinan-backend"]
```

## 📝 License

MIT



