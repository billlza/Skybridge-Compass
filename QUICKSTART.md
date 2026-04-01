# 🚀 快速开始指南

本指南帮助您在 5 分钟内快速部署云桥司南网站。

## ⚡ 一键部署（推荐）

### 前提条件

- 安装 [Docker Desktop](https://www.docker.com/products/docker-desktop) (包含 Docker 和 Docker Compose)
- 拥有 Supabase 账号和项目

### 步骤

1. **克隆代码**
   ```bash
   git clone <repository-url>
   cd yunqiao-sinan-source-code
   ```

2. **配置环境**
   ```bash
   # 创建环境配置文件
   cp env.example .env
   
   # 编辑 .env 文件，填入你的 Supabase 配置
   # 可以使用任何文本编辑器，例如：
   nano .env
   # 或
   vim .env
   ```

3. **一键部署**
   ```bash
   ./deploy.sh
   ```

4. **访问网站**
   - 前端：http://localhost
   - 后端：http://localhost:3000

就这么简单！🎉

## 📋 获取 Supabase 配置

1. 登录 [Supabase Dashboard](https://app.supabase.com)
2. 选择你的项目
3. 进入 **Settings** → **API**
4. 复制以下信息：
   - **Project URL** → `VITE_SUPABASE_URL`
   - **anon public key** → `VITE_SUPABASE_ANON_KEY`
   - **service_role secret** → `SUPABASE_SERVICE_ROLE_KEY` (仅后端使用)
5. 进入 **Settings** → **Database** → **Connection string** → **URI**
   - 复制连接字符串 → `DATABASE_URL`

## 🛠️ 常用命令

```bash
# 查看服务状态
docker-compose ps

# 查看实时日志
./deploy.sh logs

# 停止服务
./deploy.sh stop

# 重启服务
./deploy.sh stop
./deploy.sh

# 仅部署前端
./deploy.sh frontend

# 仅部署后端
./deploy.sh backend

# 清理所有资源（谨慎使用）
./deploy.sh cleanup
```

## 🔍 验证部署

### 检查前端
```bash
curl http://localhost/health
# 应该返回: healthy
```

### 检查后端
```bash
curl http://localhost:3000/health
# 应该返回 JSON 格式的健康状态
```

### 查看日志
```bash
# 查看所有日志
docker-compose logs -f

# 仅查看前端日志
docker-compose logs -f frontend

# 仅查看后端日志
docker-compose logs -f backend
```

## ❓ 遇到问题？

### 问题：端口被占用

**错误信息：** `Error: listen EADDRINUSE: address already in use`

**解决方法：**
```bash
# 查找占用端口的进程
lsof -i :80     # 检查 80 端口
lsof -i :3000   # 检查 3000 端口

# 停止占用端口的进程，或修改 docker-compose.yml 中的端口映射
```

### 问题：Docker 无法启动

**解决方法：**
```bash
# 重启 Docker Desktop
# 或使用命令行重启 Docker 服务（Linux/Mac）
sudo systemctl restart docker  # Linux
```

### 问题：环境变量未生效

**解决方法：**
```bash
# 确保 .env 文件在正确位置
ls -la .env

# 重新构建容器
docker-compose down
docker-compose up -d --build
```

### 问题：无法访问网站

**检查清单：**
1. ✅ 确认 Docker 容器正在运行：`docker-compose ps`
2. ✅ 检查防火墙设置
3. ✅ 验证环境变量配置
4. ✅ 查看错误日志：`docker-compose logs`

## 🌐 生产环境部署

对于生产环境，建议：

1. **使用反向代理（如 Nginx）**
   - 配置 HTTPS
   - 启用 HTTP/2
   - 添加 SSL 证书

2. **设置环境变量**
   - 修改 `CORS_ORIGINS` 为实际域名
   - 使用强密码和密钥
   - 不要暴露 Service Role Key

3. **监控和日志**
   - 设置日志轮转
   - 配置监控告警
   - 定期备份数据库

4. **性能优化**
   - 启用 CDN
   - 配置缓存策略
   - 使用负载均衡

详细信息请参考 [DEPLOYMENT.md](./DEPLOYMENT.md)

## 📚 更多资源

- [完整部署文档](./DEPLOYMENT.md)
- [后端 API 文档](./rust-backend/README.md)
- [项目 README](./README.md)

## 💡 提示

- 首次构建可能需要 5-10 分钟（取决于网速）
- 确保有稳定的网络连接
- 建议至少 2GB RAM 和 10GB 磁盘空间
- 开发时可以使用 `pnpm dev` 启动热重载

---

祝您部署顺利！如有问题，欢迎提 Issue。

