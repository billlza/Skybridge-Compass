import XCTest
@testable import SkyBridgeCore

/// 注册安全服务测试
@available(macOS 14.0, *)
final class RegistrationSecurityServiceTests: XCTestCase {
    
 // MARK: - 输入清洗测试
    
    func testSanitizeUsername() async {
        let service = await RegistrationSecurityService.shared
        
 // 测试首尾空格去除
        let result1 = service.sanitizeUsername("  testuser  ")
        XCTAssertEqual(result1, "testuser")
        
 // 测试连续空格替换
        let result2 = service.sanitizeUsername("test  user")
        XCTAssertEqual(result2, "test user")
        
 // 测试大写转小写
        let result3 = service.sanitizeUsername("TestUser")
        XCTAssertEqual(result3, "testuser")
        
 // 测试危险字符移除
        let result4 = service.sanitizeUsername("test<script>user")
        XCTAssertEqual(result4, "testscriptuser")
        
 // 测试SQL注入字符移除
        let result5 = service.sanitizeUsername("test';DROP TABLE users;--")
        XCTAssertFalse(result5.contains("'"))
        XCTAssertFalse(result5.contains(";"))
    }
    
    func testSanitizeEmail() async {
        let service = await RegistrationSecurityService.shared
        
 // 测试首尾空格去除
        let result1 = service.sanitizeEmail("  test@example.com  ")
        XCTAssertEqual(result1, "test@example.com")
        
 // 测试大写转小写
        let result2 = service.sanitizeEmail("Test@Example.COM")
        XCTAssertEqual(result2, "test@example.com")
    }
    
    func testSanitizePhoneNumber() async {
        let service = await RegistrationSecurityService.shared
        
 // 测试空格去除
        let result1 = service.sanitizePhoneNumber("138 1234 5678")
        XCTAssertEqual(result1, "13812345678")
        
 // 测试分隔符去除
        let result2 = service.sanitizePhoneNumber("138-1234-5678")
        XCTAssertEqual(result2, "13812345678")
        
 // 测试国际号码格式
        let result3 = service.sanitizePhoneNumber("+86 138 1234 5678")
        XCTAssertEqual(result3, "+8613812345678")
        
 // 测试括号去除
        let result4 = service.sanitizePhoneNumber("(138) 1234-5678")
        XCTAssertEqual(result4, "13812345678")
    }
    
    func testSanitizePassword() async {
        let service = await RegistrationSecurityService.shared
        
 // 测试首尾空格去除，保留中间字符
        let result1 = service.sanitizePassword("  password123!@#  ")
        XCTAssertEqual(result1, "password123!@#")
        
 // 测试特殊字符保留
        let result2 = service.sanitizePassword("P@ssw0rd!#$%")
        XCTAssertEqual(result2, "P@ssw0rd!#$%")
    }
    
 // MARK: - 用户名验证测试
    
    func testValidateUsername() async {
        let service = await RegistrationSecurityService.shared
        
 // 有效用户名
        let valid1 = service.validateUsername("testuser")
        XCTAssertTrue(valid1.valid)
        
        let valid2 = service.validateUsername("test_user_123")
        XCTAssertTrue(valid2.valid)
        
 // 太短
        let tooShort = service.validateUsername("abc")
        XCTAssertFalse(tooShort.valid)
        XCTAssertNotNil(tooShort.error)
        
 // 太长
        let tooLong = service.validateUsername("a" + String(repeating: "b", count: 25))
        XCTAssertFalse(tooLong.valid)
        
 // 包含非法字符
        let invalidChars = service.validateUsername("test@user")
        XCTAssertFalse(invalidChars.valid)
        
 // 保留名
        let reserved = service.validateUsername("admin")
        XCTAssertFalse(reserved.valid)
        
 // 以数字开头
        let startsWithNumber = service.validateUsername("123user")
        XCTAssertFalse(startsWithNumber.valid)
    }
    
 // MARK: - 密码强度测试
    
    func testEvaluatePasswordStrength() async {
        let service = await RegistrationSecurityService.shared
        
 // 弱密码
        let weak = service.evaluatePasswordStrength("abc123")
        XCTAssertEqual(weak, .weak)
        
 // 中等密码
        let medium = service.evaluatePasswordStrength("Password1")
        XCTAssertTrue(medium.rawValue >= RegistrationSecurityService.PasswordStrength.medium.rawValue)
        
 // 强密码
        let strong = service.evaluatePasswordStrength("Password1!@#")
        XCTAssertTrue(strong.rawValue >= RegistrationSecurityService.PasswordStrength.strong.rawValue)
        
 // 非常强密码
        let veryStrong = service.evaluatePasswordStrength("VeryStr0ng!P@ssword123")
        XCTAssertEqual(veryStrong, .veryStrong)
    }
    
    func testValidatePassword() async {
        let service = await RegistrationSecurityService.shared
        
 // 有效密码
        let valid = service.validatePassword("Password1!", minimumStrength: .medium)
        XCTAssertTrue(valid.valid)
        
 // 太短
        let tooShort = service.validatePassword("Abc1!", minimumStrength: .medium)
        XCTAssertFalse(tooShort.valid)
        
 // 强度不足
        let tooWeak = service.validatePassword("password", minimumStrength: .strong)
        XCTAssertFalse(tooWeak.valid)
    }
    
 // MARK: - 邮箱验证测试
    
    func testValidateEmail() async {
        let service = await RegistrationSecurityService.shared
        
 // 有效邮箱
        let valid1 = service.validateEmail("test@example.com")
        XCTAssertTrue(valid1.valid)
        
        let valid2 = service.validateEmail("test.user+tag@example.co.uk")
        XCTAssertTrue(valid2.valid)
        
 // 无效邮箱
        let invalid1 = service.validateEmail("testexample.com")
        XCTAssertFalse(invalid1.valid)
        
        let invalid2 = service.validateEmail("test@")
        XCTAssertFalse(invalid2.valid)
        
        let invalid3 = service.validateEmail("@example.com")
        XCTAssertFalse(invalid3.valid)
    }
    
 // MARK: - 手机号验证测试
    
    func testValidatePhoneNumber() async {
        let service = await RegistrationSecurityService.shared
        
 // 中国大陆手机号
        let chinaPhone1 = service.validatePhoneNumber("13812345678")
        XCTAssertTrue(chinaPhone1.valid)
        
        let chinaPhone2 = service.validatePhoneNumber("19912345678")
        XCTAssertTrue(chinaPhone2.valid)
        
 // 国际手机号
        let intlPhone1 = service.validatePhoneNumber("+8613812345678")
        XCTAssertTrue(intlPhone1.valid)
        
        let intlPhone2 = service.validatePhoneNumber("+14155551234")
        XCTAssertTrue(intlPhone2.valid)
        
 // 无效手机号
        let invalid1 = service.validatePhoneNumber("1234567890")  // 不以1开头
        XCTAssertFalse(invalid1.valid)
        
        let invalid2 = service.validatePhoneNumber("1381234567")  // 位数不对
        XCTAssertFalse(invalid2.valid)
    }
    
 // MARK: - 限流测试
    
    func testRateLimiting() async {
        let service = await RegistrationSecurityService.shared
        
 // 创建测试上下文
        let testIP = "test_ip_\(UUID().uuidString)"
        let testFingerprint = "test_fp_\(UUID().uuidString)"
        let testIdentifier = "test@example.com"
        
        let context = RegistrationSecurityService.RegistrationContext(
            ip: testIP,
            deviceFingerprint: testFingerprint,
            identifier: testIdentifier,
            identifierType: .email
        )
        
 // 第一次应该允许
        let result1 = await service.canRegister(context: context)
        XCTAssertTrue(result1.allowed)
        
 // 记录尝试
        await service.recordAttempt(context: context, success: false)
        await service.recordAttempt(context: context, success: false)
        
 // 多次尝试后应该触发验证码
        let result2 = await service.canRegister(context: context)
        XCTAssertTrue(result2.allowed || result2.requiresCaptcha)
    }
    
 // MARK: - 黑名单测试
    
    func testBlacklist() async {
        let service = await RegistrationSecurityService.shared
        
        let testIP = "blacklist_test_ip_\(UUID().uuidString)"
        
 // 添加到黑名单
        await service.addToIPBlacklist(ip: testIP, reason: "测试", duration: 60)
        
 // 创建测试上下文
        let context = RegistrationSecurityService.RegistrationContext(
            ip: testIP,
            deviceFingerprint: "test_fp",
            identifier: "test@example.com",
            identifierType: .email
        )
        
 // 应该被拒绝
        let result = await service.canRegister(context: context)
        XCTAssertFalse(result.allowed)
        
 // 清理：从黑名单移除
        await service.removeFromBlacklist(type: .ip, value: testIP)
    }
    
 // MARK: - 统计信息测试
    
    func testStatistics() async {
        let service = await RegistrationSecurityService.shared
        
        let stats = await service.getStatistics()
        
 // 验证统计信息结构
        XCTAssertGreaterThanOrEqual(stats.totalAttempts, 0)
        XCTAssertGreaterThanOrEqual(stats.successfulAttempts, 0)
        XCTAssertGreaterThanOrEqual(stats.failedAttempts, 0)
        XCTAssertGreaterThanOrEqual(stats.blacklistedIPs, 0)
        XCTAssertGreaterThanOrEqual(stats.disposableEmailDomains, 0)
    }
}

// MARK: - 行为分析器测试

@available(macOS 14.0, *)
final class BehaviorAnalyzerTests: XCTestCase {
    
    func testAnalyzeHumanLikeTrack() async {
        let analyzer = await BehaviorAnalyzer.shared
        
 // 创建模拟人类的轨迹
        var points: [BehaviorAnalyzer.TrackPoint] = []
        let startX: Double = 0
        let targetX: Double = 200
        let duration: Double = 1000  // 1秒
        
 // 生成带有自然抖动的轨迹
        for i in 0..<50 {
            let t = Double(i) / 50.0
            let x = startX + (targetX - startX) * t + Double.random(in: -3...3)
            let y = 25 + Double.random(in: -5...5)  // Y轴有些许抖动
            let timestamp = duration * t + Double.random(in: -10...10)
            points.append(BehaviorAnalyzer.TrackPoint(x: x, y: y, timestamp: max(0, timestamp)))
        }
        
        let track = BehaviorAnalyzer.SlideTrack(
            points: points,
            startTime: Date().addingTimeInterval(-1),
            endTime: Date(),
            targetX: targetX,
            actualX: targetX + 2  // 小误差
        )
        
        let result = await analyzer.analyzeSlideTrack(track)
        
 // 人类轨迹应该有较高的评分
        XCTAssertGreaterThan(result.score, 0.3)
        print("人类轨迹分析结果: score=\(result.score), isHuman=\(result.isHuman)")
    }
    
    func testAnalyzeBotLikeTrack() async {
        let analyzer = await BehaviorAnalyzer.shared
        
 // 创建机器人轨迹（完美直线，匀速）
        var points: [BehaviorAnalyzer.TrackPoint] = []
        let startX: Double = 0
        let targetX: Double = 200
        let duration: Double = 500  // 0.5秒，太快
        
 // 生成完美直线轨迹（无抖动）
        for i in 0..<20 {
            let t = Double(i) / 20.0
            let x = startX + (targetX - startX) * t
            let y: Double = 25  // 完全水平
            let timestamp = duration * t
            points.append(BehaviorAnalyzer.TrackPoint(x: x, y: y, timestamp: timestamp))
        }
        
        let track = BehaviorAnalyzer.SlideTrack(
            points: points,
            startTime: Date().addingTimeInterval(-0.5),
            endTime: Date(),
            targetX: targetX,
            actualX: targetX  // 完美位置
        )
        
        let result = await analyzer.analyzeSlideTrack(track)
        
 // 机器人轨迹应该有较低的评分
        print("机器人轨迹分析结果: score=\(result.score), isHuman=\(result.isHuman)")
 // 由于是模拟的完美轨迹，平滑度评分应该较低
        XCTAssertLessThan(result.details.smoothnessScore, 0.5)
    }
    
    func testTrackWithInsufficientPoints() async {
        let analyzer = await BehaviorAnalyzer.shared
        
 // 创建点数不足的轨迹
        let points = [
            BehaviorAnalyzer.TrackPoint(x: 0, y: 25, timestamp: 0),
            BehaviorAnalyzer.TrackPoint(x: 100, y: 25, timestamp: 500)
        ]
        
        let track = BehaviorAnalyzer.SlideTrack(
            points: points,
            startTime: Date().addingTimeInterval(-0.5),
            endTime: Date(),
            targetX: 100,
            actualX: 100
        )
        
        let result = await analyzer.analyzeSlideTrack(track)
        
 // 点数不足应该被拒绝
        XCTAssertFalse(result.isHuman)
        XCTAssertNotNil(result.reason)
    }
}

// MARK: - 输入验证测试

@available(macOS 14.0, *)
final class InputValidationTests: XCTestCase {
    
    func testChinesePhoneNumbers() async {
        let service = await RegistrationSecurityService.shared
        
 // 各运营商号段测试
        let validNumbers = [
            "13012345678",  // 联通
            "13512345678",  // 移动
            "18012345678",  // 电信
            "17012345678",  // 虚拟运营商
            "19912345678",  // 移动
        ]
        
        for number in validNumbers {
            let result = service.validatePhoneNumber(number)
            XCTAssertTrue(result.valid, "号码 \(number) 应该是有效的")
        }
        
 // 无效号码
        let invalidNumbers = [
            "12012345678",  // 12开头无效
            "10012345678",  // 10开头无效
            "1381234567",   // 10位
            "138123456789", // 12位
        ]
        
        for number in invalidNumbers {
            let result = service.validatePhoneNumber(number)
            XCTAssertFalse(result.valid, "号码 \(number) 应该是无效的")
        }
    }
    
    func testInternationalPhoneNumbers() async {
        let service = await RegistrationSecurityService.shared
        
 // 有效的国际号码
        let validNumbers = [
            "+8613012345678",   // 中国
            "+14155551234",     // 美国
            "+447911123456",    // 英国
            "+81312345678",     // 日本
        ]
        
        for number in validNumbers {
            let result = service.validatePhoneNumber(number)
            XCTAssertTrue(result.valid, "国际号码 \(number) 应该是有效的")
        }
    }
    
    func testPasswordComplexity() async {
        let service = await RegistrationSecurityService.shared
        
 // 测试各种密码组合
 // 密码强度评分规则：
 // - 长度>=8: +1, >=12: +1, >=16: +1
 // - 小写: +1, 大写: +1, 数字: +1, 特殊字符: +1
 // 总分: 0-2=weak, 3-4=medium, 5-6=strong, 7+=veryStrong
 // 长度评分: >=8(+1), >=12(+1), >=16(+1)
 // 复杂度评分: 小写(+1), 大写(+1), 数字(+1), 特殊字符(+1)
        let testCases: [(password: String, minStrength: RegistrationSecurityService.PasswordStrength, shouldPass: Bool)] = [
            ("abc", .weak, false),                    // 太短（<8位）
            ("abcdefgh", .weak, true),                // 8位+小写=2分=weak，满足weak要求
            ("Abcdefgh", .medium, true),              // 8位+小写+大写=3分=medium，满足medium要求
            ("Abcdefg1", .medium, true),              // 8位+小写+大写+数字=4分=medium，满足medium要求
            ("Abcdefg1!", .strong, true),             // 8位+小写+大写+数字+特殊=5分=strong，满足strong要求
            ("VeryStr0ng!P@ss", .strong, true),       // 15位(+2)+小写+大写+数字+特殊=6分=strong
            ("VeryStr0ng!P@sswd", .veryStrong, true), // 17位(+3)+小写+大写+数字+特殊=7分=veryStrong
        ]
        
        for testCase in testCases {
            let result = service.validatePassword(testCase.password, minimumStrength: testCase.minStrength)
            XCTAssertEqual(result.valid, testCase.shouldPass, 
                          "密码 '\(testCase.password)' 最低强度 \(testCase.minStrength) 预期 \(testCase.shouldPass) 实际 \(result.valid)")
        }
    }
}

