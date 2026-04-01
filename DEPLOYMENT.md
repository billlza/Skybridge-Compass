# 云桥司南 - 部署文档

本文档详细说明了如何部署云桥司南网站的前端和后端服务。

## 📋 目录

- [系统要求](#系统要求)
- [快速开始](#快速开始)
- [配置说明](#配置说明)
- [部署方式](#部署方式)
  - [Docker 部署（推荐）](#docker-部署推荐)
  - [手动部署](#手动部署)
  - [云平台部署](#云平台部署)
- [监控和维护](#监控和维护)
- [故障排查](#故障排查)

## 🖥️ 系统要求

### Docker 部署（推荐）
- Docker 20.10+
- Docker Compose 2.0+
- 2GB+ RAM
- 10GB+ 磁盘空间

### 手动部署
- Node.js 20+
- pnpm 10+
- Rust 1.75+ (如果使用 Rust 后端)
- PostgreSQL 14+ (通过 Supabase 或自托管)

## 🚀 快速开始

### 1. 克隆仓库

```bash
git clone <repository-url>
cd yunqiao-sinan-source-code
```

### 2. 配置环境变量

创建 `.env` 文件（从模板复制）：

```bash
# 前端环境变量
VITE_SUPABASE_URL=https://hloqytmhjludmuhwyyzb.supabase.co
VITE_SUPABASE_ANON_KEY=your-anon-key

# 后端环境变量（如果使用 Rust 后端）
DATABASE_URL=postgresql://user:password@host:5432/dbname
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
JWT_SECRET=your-jwt-secret
CORS_ORIGINS=http://localhost:3000,http://127.0.0.1:3000,http://localhost:4173,http://127.0.0.1:4173,https://skybridge-compass.vercel.app
LOG_LEVEL=info
```

### 3. 部署

使用部署脚本：

```bash
chmod +x deploy.sh
./deploy.sh
```

或使用 Docker Compose：

```bash
docker-compose up -d
```

### 4. 验证部署

```bash
# 检查服务状态
docker-compose ps

# 查看日志
docker-compose logs -f

# 访问服务
# 前端: http://localhost
# 后端: http://localhost:3000
```

## ⚙️ 配置说明

### 前端配置

在 `.env` 或构建时设置以下环境变量：

| 变量名 | 描述 | 必需 | 默认值 |
|--------|------|------|--------|
| `VITE_SUPABASE_URL` | Supabase 项目 URL | 是 | - |
| `VITE_SUPABASE_ANON_KEY` | Supabase 匿名密钥 | 是 | - |

### 后端配置

Rust 后端配置（如果使用）：

| 变量名 | 描述 | 必需 | 默认值 |
|--------|------|------|--------|
| `HOST` | 监听地址 | 否 | `0.0.0.0` |
| `PORT` | 监听端口 | 否 | `3000` |
| `DATABASE_URL` | PostgreSQL 连接字符串 | 是 | - |
| `SUPABASE_URL` | Supabase URL | 是 | - |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase 服务密钥 | 是 | - |
| `SUPABASE_ANON_KEY` | Supabase 匿名密钥 | 是 | - |
| `JWT_SECRET` | JWT 签名密钥 | 是 | - |
| `CORS_ORIGINS` | 允许的跨域源 | 否 | `*` |
| `LOG_LEVEL` | 日志级别 | 否 | `info` |

## 📦 部署方式

### Docker 部署（推荐）

#### 完整部署（前端 + 后端）

```bash
# 构建并启动所有服务
docker-compose up -d

# 查看日志
docker-compose logs -f

# 停止服务
docker-compose down

# 重新构建并部署
docker-compose up -d --build
```

#### 仅部署前端

```bash
docker-compose up -d frontend
```

#### 仅部署后端

```bash
docker-compose up -d backend
```

#### 使用部署脚本

```bash
# 部署所有服务
./deploy.sh all

# 仅部署前端
./deploy.sh frontend

# 仅部署后端
./deploy.sh backend

# 停止服务
./deploy.sh stop

# 查看日志
./deploy.sh logs

# 清理所有资源
./deploy.sh cleanup
```

### 手动部署

#### 前端部署

```bash
# 安装依赖
pnpm install

# 构建生产版本
pnpm build:prod

# dist/ 目录包含构建产物
# 使用任何静态文件服务器托管，例如 Nginx
```

**Nginx 配置示例：**

```nginx
server {
    listen 80;
    server_name your-domain.com;
    
    root /path/to/dist;
    index index.html;
    
    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

#### 后端部署（Rust）

```bash
cd rust-backend

# 配置环境变量
cp env.example .env
# 编辑 .env 文件

# 构建发布版本
cargo build --release

# 运行
./target/release/sinan-backend
```

**使用 systemd 服务：**

```ini
# /etc/systemd/system/sinan-backend.service
[Unit]
Description=Sinan Backend Service
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/sinan-backend
EnvironmentFile=/opt/sinan-backend/.env
ExecStart=/opt/sinan-backend/sinan-backend
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

启动服务：

```bash
sudo systemctl enable sinan-backend
sudo systemctl start sinan-backend
sudo systemctl status sinan-backend
```

### 云平台部署

#### Vercel（前端推荐）

1. 安装 Vercel CLI：
   ```bash
   npm i -g vercel
   ```

2. 部署：
   ```bash
   vercel --prod
   ```

3. 在 Vercel 控制台配置环境变量：
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`

#### Netlify（前端）

1. 创建 `netlify.toml`：
   ```toml
   [build]
     command = "pnpm build:prod"
     publish = "dist"

   [[redirects]]
     from = "/*"
     to = "/index.html"
     status = 200
   ```

2. 连接 Git 仓库并部署

#### Railway / Render（后端）

1. 连接 Git 仓库
2. 配置构建命令：
   ```bash
   cd rust-backend && cargo build --release
   ```
3. 配置启动命令：
   ```bash
   ./rust-backend/target/release/sinan-backend
   ```
4. 添加环境变量

#### Docker Hub / AWS / GCP / Azure

使用提供的 Dockerfile 构建镜像并推送：

```bash
# 构建前端镜像
docker build -t sinan-frontend:latest -f Dockerfile.frontend .

# 构建后端镜像
docker build -t sinan-backend:latest -f rust-backend/Dockerfile ./rust-backend

# 推送到 Docker Hub
docker tag sinan-frontend:latest username/sinan-frontend:latest
docker push username/sinan-frontend:latest

docker tag sinan-backend:latest username/sinan-backend:latest
docker push username/sinan-backend:latest
```

## 📊 监控和维护

### 健康检查

前端和后端都配置了健康检查端点：

- **前端**: `http://localhost/health`
- **后端**: `http://localhost:3000/health`

### 查看日志

```bash
# Docker 日志
docker-compose logs -f frontend
docker-compose logs -f backend

# 系统日志（如果使用 systemd）
sudo journalctl -u sinan-backend -f
```

### 备份数据库

使用 Supabase 的备份功能，或手动备份 PostgreSQL：

```bash
pg_dump -h host -U user -d database > backup.sql
```

### 更新部署

```bash
# 拉取最新代码
git pull

# 重新构建并部署
docker-compose up -d --build

# 或使用部署脚本
./deploy.sh all
```

### 回滚版本

```bash
# 使用特定镜像版本
docker-compose down
docker pull username/sinan-frontend:v1.0.0
docker-compose up -d
```

## 🔧 故障排查

### 前端问题

**问题：页面空白或加载失败**

1. 检查环境变量是否正确配置
2. 查看浏览器控制台错误
3. 验证 Supabase URL 和密钥
4. 检查 Nginx 日志：
   ```bash
   docker-compose logs frontend
   ```

**问题：API 请求失败**

1. 检查 CORS 配置
2. 验证 Supabase Functions 是否正常运行
3. 检查网络连接和防火墙规则

### 后端问题

**问题：后端无法启动**

1. 检查环境变量配置：
   ```bash
   docker-compose config
   ```
2. 验证数据库连接：
   ```bash
   docker-compose logs backend | grep "database"
   ```
3. 检查端口占用：
   ```bash
   lsof -i :3000
   ```

**问题：数据库连接失败**

1. 验证 `DATABASE_URL` 格式
2. 检查数据库服务器是否可访问
3. 验证凭据和权限

### Docker 问题

**问题：容器无法启动**

```bash
# 查看详细日志
docker-compose logs

# 重新构建镜像
docker-compose build --no-cache

# 清理并重启
docker-compose down -v
docker-compose up -d
```

**问题：磁盘空间不足**

```bash
# 清理未使用的资源
docker system prune -a --volumes
```

### 性能优化

1. **启用 CDN**：使用 Cloudflare 或其他 CDN 服务
2. **优化镜像大小**：使用多阶段构建（已配置）
3. **增加资源**：调整 Docker 内存和 CPU 限制
4. **启用缓存**：Nginx 已配置静态资源缓存
5. **数据库优化**：为常用查询添加索引

## 📞 支持

如遇问题，请：

1. 查看日志文件
2. 检查环境变量配置
3. 参考本文档的故障排查部分
4. 提交 Issue 到 GitHub 仓库

## 📝 附录

### 端口映射

| 服务 | 内部端口 | 外部端口 |
|------|---------|---------|
| 前端 | 80 | 80 |
| 后端 | 3000 | 3000 |

### 目录结构

```
yunqiao-sinan-source-code/
├── src/                    # 前端源码
├── rust-backend/          # 后端源码
├── dist/                  # 前端构建产物
├── Dockerfile.frontend    # 前端 Docker 配置
├── docker-compose.yml     # Docker Compose 配置
├── nginx.conf            # Nginx 配置
├── deploy.sh             # 部署脚本
└── DEPLOYMENT.md         # 本文档
```

## 🎉 完成

恭喜！您已成功部署云桥司南网站。祝使用愉快！
