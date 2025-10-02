# 远程仓库配置指南

## 配置 GitHub 远程仓库

在本地开发环境中执行以下命令：

```bash
# 添加远程仓库
git remote add origin git@github.com:billlza/Skybridge-Compass.git

# 推送 work 分支到远程
git push -u origin work

# 或者合并到 main 分支
git checkout main
git merge work
git push origin main
```

## 注意事项

- 确保 SSH 密钥已配置
- 确保有推送权限
- 建议先备份本地修改

## 运营中枢四字化命名调整

ChatGPT 已完成以下修改：
- 将"运营中枢"相关命名缩短为四字
- 优化了控制台命名
- 提交 ID: 92e9b30

## 推送步骤

1. 配置远程仓库
2. 推送 work 分支
3. 合并到 main 分支
4. 验证修改
