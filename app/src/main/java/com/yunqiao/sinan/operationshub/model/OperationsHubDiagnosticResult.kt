package com.yunqiao.sinan.operationshub.model

/**
 * 运营枢纽诊断结果数据类
 */
data class OperationsHubDiagnosticResult(
    /** 总体状态 */
    val overallStatus: DiagnosticStatus,
    
    /** 总体分数 (0.0-1.0) */
    val overallScore: Float,
    
    /** 组件诊断结果列表 */
    val components: List<ComponentDiagnostic>,
    
    /** 诊断时间 */
    val timestamp: Long = System.currentTimeMillis(),
    
    /** 诊断耗时（毫秒） */
    val diagnosticDuration: Long = 0L,
    
    /** 建议操作列表 */
    val recommendations: List<String> = emptyList()
)

/**
 * 组件诊断数据类
 */
data class ComponentDiagnostic(
    /** 组件名称 */
    val componentName: String,
    
    /** 组件状态 */
    val status: DiagnosticStatus,
    
    /** 组件分数 (0.0-1.0) */
    val score: Float,
    
    /** 详细信息 */
    val details: String? = null,
    
    /** 错误信息 */
    val errorMessage: String? = null,
    
    /** 建议操作 */
    val recommendation: String? = null
)
