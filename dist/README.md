# 打包说明

`Skybridge-Compass-work.zip` 包含当前 `work` 分支的所有源代码与资源文件，已排除 `.git/` 目录与 `dist/` 目录自身，便于直接下载与分享。

## 使用方式
1. 解压 `Skybridge-Compass-work.zip`。
2. 在解压后的目录中按照 `BUILDING.md` 的离线构建说明配置环境。
3. 如需重新生成压缩包，可在项目根目录运行：
   ```bash
   mkdir -p dist
   zip -r dist/Skybridge-Compass-work.zip . -x ".git/*" "dist/*"
   ```

> 若需要其它格式（如 tar.gz），可使用 `tar -czf` 等命令自行生成。
