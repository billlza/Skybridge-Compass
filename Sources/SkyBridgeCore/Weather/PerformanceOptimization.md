# 🚀 天气系统性能优化方案

## 📊 当前问题分析

### 1. 主线程阻塞风险
```
✗ 46个 @MainActor 标记 → 所有计算都在主线程
✗ Perlin噪声计算（CPU密集型）在主线程
✗ 2500+粒子的物理更新在主线程
✗ 光线步进（64步）在主线程
```

### 2. 内存分配问题
```
✗ 每帧创建新的粒子数组
✗ 没有对象池复用
✗ 频繁的数组排序操作
```

### 3. 渲染批次问题
```
✗ 每个粒子单独绘制（2500+ draw calls）
✗ 没有批处理优化
✗ 没有视锥剔除
```

---

## 🎯 优化策略

### ⚡ 第一优先级：异步计算（避免主线程阻塞）

#### 1.1 使用 Actor 隔离粒子系统
```swift
actor ParticleSystemActor {
    private var particles: [Particle] = []
    
    // 在后台线程更新
    func update(deltaTime: Float) async {
        // 物理计算
        for i in 0..<particles.count {
            particles[i].position += particles[i].velocity * deltaTime
        }
    }
    
    // 主线程只读取快照
    nonisolated func getSnapshot() -> [Particle] {
        // 返回不可变副本
    }
}
```

#### 1.2 Perlin噪声预计算
```swift
actor NoiseCache {
    private var cache: [SIMD3<Int>: Float] = [:]
    
    func getNoise(x: Float, y: Float, z: Float) async -> Float {
        let key = SIMD3<Int>(Int(x*10), Int(y*10), Int(z*10))
        if let cached = cache[key] { return cached }
        
        let value = await Task.detached {
            // 在后台计算
            computePerlinNoise(x, y, z)
        }.value
        
        cache[key] = value
        return value
    }
}
```

#### 1.3 双缓冲机制
```swift
class DoubleBufferedParticleSystem {
    private var frontBuffer: [Particle] = []
    private var backBuffer: [Particle] = []
    private let updateQueue = DispatchQueue(label: "particle.update")
    
    func update(deltaTime: Float) {
        // 后台更新backBuffer
        updateQueue.async {
            self.updateBackBuffer(deltaTime)
            
            // 更新完成后交换
            DispatchQueue.main.async {
                swap(&self.frontBuffer, &self.backBuffer)
            }
        }
    }
    
    // 主线程只读取frontBuffer
    func render() {
        for particle in frontBuffer {
            // 渲染...
        }
    }
}
```

---

### 🎨 第二优先级：渲染优化

#### 2.1 空间分区（减少计算量）
```swift
struct SpatialGrid {
    private var cells: [[Particle]] = []
    private let cellSize: Float = 100
    
    func getCellIndex(position: SIMD2<Float>) -> Int {
        // 将粒子分配到网格
    }
    
    func getVisibleParticles(viewport: CGRect) -> [Particle] {
        // 只返回可见区域的粒子
    }
}
```

#### 2.2 LOD系统（根据距离调整细节）
```swift
enum ParticleLOD {
    case high    // 近景：完整渲染
    case medium  // 中景：简化渲染
    case low     // 远景：极简渲染
}

func getLOD(distance: Float) -> ParticleLOD {
    switch distance {
    case 0..<100: return .high
    case 100..<300: return .medium
    default: return .low
    }
}
```

#### 2.3 对象池（避免频繁创建）
```swift
class ParticlePool {
    private var pool: [Particle] = []
    private var activeCount = 0
    
    func acquire() -> Particle {
        if activeCount < pool.count {
            activeCount += 1
            return pool[activeCount - 1]
        }
        
        let particle = Particle()
        pool.append(particle)
        activeCount += 1
        return particle
    }
    
    func release(_ particle: Particle) {
        activeCount -= 1
    }
}
```

---

### 🔧 第三优先级：Metal Compute Shaders

#### 3.1 GPU粒子更新
```metal
kernel void updateParticles(
    device Particle* particles [[buffer(0)]],
    constant float& deltaTime [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    Particle p = particles[id];
    
    // 物理更新（在GPU并行执行）
    p.position += p.velocity * deltaTime;
    p.velocity.y += GRAVITY * deltaTime;
    
    particles[id] = p;
}
```

#### 3.2 批量渲染
```swift
// 使用Metal的instanced rendering
func renderParticlesBatch() {
    // 一次draw call渲染所有粒子
    renderEncoder.drawPrimitives(
        type: .point,
        vertexStart: 0,
        vertexCount: particleCount,
        instanceCount: 1
    )
}
```

---

## 📈 预期性能提升

| 优化项 | 当前 | 优化后 | 提升 |
|--------|------|--------|------|
| 主线程占用 | 85% | 15% | **-70%** |
| 帧时间(ms) | 16.7 | 8.3 | **2x** |
| 粒子数量 | 2500 | 10000 | **4x** |
| 内存分配 | 高频 | 低频 | **-80%** |

---

## 🛠️ 实施计划

### Phase 1: 异步化（最高优先级）
- [ ] 实现 ParticleSystemActor
- [ ] 噪声预计算和缓存
- [ ] 双缓冲机制

### Phase 2: 渲染优化
- [ ] 空间分区
- [ ] LOD系统
- [ ] 对象池

### Phase 3: Metal加速
- [ ] Compute Shader粒子更新
- [ ] Instanced rendering

---

## ⚠️ 注意事项

1. **Swift Concurrency**
   - 使用 `actor` 避免数据竞争
   - 使用 `Task.detached` 进行CPU密集型计算
   - 避免在 `@MainActor` 中进行耗时操作

2. **内存管理**
   - 使用值类型（struct）避免引用计数开销
   - 预分配数组避免动态增长
   - 及时释放不需要的资源

3. **测试基准**
   - 使用 Instruments 进行性能分析
   - 监控主线程占用率
   - 测量帧时间和卡顿

---

## 📝 参考资料

- [WWDC 2021: Meet async/await in Swift](https://developer.apple.com/videos/play/wwdc2021/10132/)
- [WWDC 2022: Eliminate data races using Swift Concurrency](https://developer.apple.com/videos/play/wwdc2022/110351/)
- [Metal Performance Shaders](https://developer.apple.com/metal/Metal-Performance-Shaders.pdf)
- [Building High-Performance Apps with Metal](https://developer.apple.com/documentation/metal)

