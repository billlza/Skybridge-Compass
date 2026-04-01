# 云桥司南 (Skybridge Sinan)

<div align="center">
  <img src="public/logo.png" alt="云桥司南 Logo" width="120" />
  <p><strong>融合东方智慧与现代科技，为您在数字星海中指引方向</strong></p>
</div>

## 🌟 项目简介

云桥司南是一个现代化的全栈 Web 应用，结合了美观的用户界面和强大的后端功能。项目采用前后端分离架构，前端基于 React + TypeScript + Vite，后端支持 Rust (Axum) 或 Supabase Edge Functions。

### ✨ 核心特性

- 🎨 **唯美星云背景** - 动态、流体的星云效果，如同画卷般的视觉体验
- 🔐 **完整的用户认证** - 支持邮箱和手机号注册登录
- 📱 **响应式设计** - 完美适配桌面和移动设备
- 🚀 **高性能** - 基于 Vite 和 Rust 的极速体验
- 🎭 **Glassmorphism UI** - Apple 风格的玻璃态设计
- 🌐 **多账户绑定** - 支持邮箱和手机号绑定

## 🛠️ 技术栈

### 前端
- **框架**: React 19 + TypeScript
- **构建工具**: Vite 7
- **样式**: Tailwind CSS 4
- **动画**: Framer Motion
- **状态管理**: Zustand + TanStack Query
- **UI 组件**: Radix UI
- **表单**: React Hook Form + Zod

### 后端
- **选项 1**: Supabase (Auth + Database + Edge Functions)
- **选项 2**: Rust + Axum + SQLx + PostgreSQL
- **认证**: JWT + Supabase Auth
- **数据库**: PostgreSQL (Supabase)

## 🚀 快速开始

### 方式一：使用 Docker（推荐）

```bash
# 1. 克隆仓库
git clone <repository-url>
cd yunqiao-sinan-source-code

# 2. 配置环境变量
cp env.example .env
# 编辑 .env 填入你的配置

# 3. 一键部署
./deploy.sh

# 4. 访问网站
# 前端: http://localhost
# 后端: http://localhost:3000
```

📚 详细部署指南请参考 [QUICKSTART.md](./QUICKSTART.md)

### 方式二：本地开发

#### 前端开发

```bash
# 安装依赖
pnpm install

# 启动开发服务器
pnpm dev

# 构建生产版本
pnpm build:prod

# 预览生产构建
pnpm preview
```

#### 后端开发（可选 - 如果使用 Rust 后端）

```bash
cd rust-backend

# 配置环境变量
cp env.example .env

# 运行开发服务器
cargo run

# 构建生产版本
cargo build --release
```

## 📁 项目结构

```
yunqiao-sinan-source-code/
├── src/                        # 前端源码
│   ├── components/            # React 组件
│   │   ├── StarryBackground.tsx   # 星云背景组件
│   │   └── Navigation.tsx         # 导航栏组件
│   ├── pages/                 # 页面组件
│   ├── contexts/              # React Context
│   ├── hooks/                 # 自定义 Hooks
│   ├── lib/                   # 工具库
│   └── stores/                # 状态管理
├── rust-backend/              # Rust 后端（可选）
│   ├── src/
│   │   ├── main.rs           # 后端入口
│   │   └── handlers/         # API 处理器
│   └── Dockerfile            # 后端 Docker 配置
├── public/                    # 静态资源
├── Dockerfile.frontend        # 前端 Docker 配置
├── docker-compose.yml         # Docker Compose 配置
├── nginx.conf                # Nginx 配置
├── deploy.sh                 # 部署脚本
├── DEPLOYMENT.md             # 完整部署文档
├── QUICKSTART.md             # 快速开始指南
└── README.md                 # 本文件
```

## 🎨 背景设计说明

项目的星云背景经过精心设计，实现了如画卷般的唯美效果：

### 设计特点
- **唯美色调**: 深紫、靛蓝、幻粉和翡翠色的和谐融合
- **流体晕染**: Canvas 绘制的大型彩色光斑，缓慢漂移融合
- **画卷质感**: SVG 噪点滤镜增加细腻的颗粒感
- **深邃空间**: 径向渐变营造宇宙景深
- **呼吸星光**: 星星以不同速率闪烁，增添生命力

技术实现位于 `src/components/StarryBackground.tsx`

## 📊 可用脚本

```bash
# 开发
pnpm dev              # 启动开发服务器
pnpm build            # 构建（开发模式）
pnpm build:prod       # 构建（生产模式）
pnpm preview          # 预览生产构建

# 代码质量
pnpm lint             # 运行 ESLint

# 清理
pnpm clean            # 清理依赖和缓存
```

## 🔧 环境变量

### 前端环境变量

在项目根目录创建 `.env` 文件：

```env
VITE_SUPABASE_URL=your-supabase-url
VITE_SUPABASE_ANON_KEY=your-anon-key
```

### 后端环境变量（如果使用 Rust 后端）

在 `rust-backend/` 目录创建 `.env` 文件：

```env
DATABASE_URL=postgresql://user:password@host:5432/dbname
SUPABASE_URL=your-supabase-url
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
JWT_SECRET=your-jwt-secret
```

详细配置说明请参考 [env.example](./env.example)

## 🌐 部署选项

项目支持多种部署方式：

### Docker 部署（推荐）
使用提供的 Docker 配置一键部署：
```bash
./deploy.sh
```

### 云平台部署
- **前端**: Vercel, Netlify, Cloudflare Pages
- **后端**: Railway, Render, Fly.io, AWS, GCP, Azure

### 传统服务器
使用 Nginx + PM2 或 Systemd 部署

📚 详细部署指南：
- [快速开始指南](./QUICKSTART.md)
- [完整部署文档](./DEPLOYMENT.md)
- [后端部署文档](./rust-backend/README.md)

## 🔐 安全注意事项

- ⚠️ 永远不要将 `.env` 文件提交到 Git
- ⚠️ 生产环境中使用强密码和密钥
- ⚠️ Service Role Key 仅在后端使用，不要暴露到前端
- ⚠️ 配置合适的 CORS 策略
- ⚠️ 启用 HTTPS（生产环境）

## 📈 性能优化

项目已内置多项性能优化：

- ✅ 多阶段 Docker 构建
- ✅ Nginx 静态资源缓存和 Gzip 压缩
- ✅ React 组件懒加载
- ✅ 图片和资源优化
- ✅ 代码分割
- ✅ Tree Shaking
- ✅ Rust 后端的零成本抽象

## 🐛 故障排查

遇到问题？请查看：

1. [快速开始指南 - 常见问题](./QUICKSTART.md#❓-遇到问题)
2. [部署文档 - 故障排查](./DEPLOYMENT.md#🔧-故障排查)
3. 查看日志：`docker-compose logs -f`
4. 检查环境变量配置
5. 提交 Issue 到 GitHub

## 📝 开发指南

### 添加新页面

1. 在 `src/pages/` 创建页面组件
2. 在 `src/App.tsx` 添加路由
3. 在 `src/components/Navigation.tsx` 添加导航链接

### 修改背景效果

编辑 `src/components/StarryBackground.tsx`：

- 调整 `colors` 数组修改色调
- 修改 `particleCount` 改变星云密度
- 调整 `vx` 和 `vy` 改变漂移速度

### API 集成

参考 `src/lib/supabase.ts` 中的示例函数

## 🤝 贡献

欢迎贡献！请：

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

## 📄 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

## 🙏 致谢

- [React](https://react.dev/)
- [Vite](https://vitejs.dev/)
- [Tailwind CSS](https://tailwindcss.com/)
- [Supabase](https://supabase.com/)
- [Axum](https://github.com/tokio-rs/axum)
- [Framer Motion](https://www.framer.com/motion/)

## 📞 联系方式

- 项目主页: [GitHub Repository]
- 问题反馈: [Issues]
- 邮箱: your-email@example.com

---

<div align="center">
  <p>用 ❤️ 打造 | Made with ❤️</p>
  <p>© 2024 云桥司南 (Skybridge Sinan)</p>
</div>
