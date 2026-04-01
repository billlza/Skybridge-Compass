// 更新用户自定义ID的边缘函数
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { getCorsHeaders } from '../_shared/security.ts'

Deno.serve(async (req) => {
  const corsHeaders = getCorsHeaders(req)
  // 处理预检请求
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 200, headers: corsHeaders })
  }

  try {
    // 获取环境变量
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    
    // 创建Supabase客户端（使用服务密钥以便管理操作）
    const supabase = createClient(supabaseUrl, supabaseServiceKey)

    // 验证HTTP方法
    if (req.method !== 'PUT') {
      return new Response(
        JSON.stringify({ 
          error: { 
            code: 'METHOD_NOT_ALLOWED', 
            message: '只支持PUT方法' 
          } 
        }),
        { 
          status: 405, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    // 获取授权token
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(
        JSON.stringify({ 
          error: { 
            code: 'UNAUTHORIZED', 
            message: '缺少授权头' 
          } 
        }),
        { 
          status: 401, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    // 验证用户身份
    const token = authHeader.replace('Bearer ', '')
    const { data: { user }, error: authError } = await supabase.auth.getUser(token)
    
    if (authError || !user) {
      return new Response(
        JSON.stringify({ 
          error: { 
            code: 'UNAUTHORIZED', 
            message: '无效的授权token' 
          } 
        }),
        { 
          status: 401, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    // 解析请求体
    const requestData = await req.json()
    const { custom_user_id } = requestData

    // 验证输入
    if (!custom_user_id || typeof custom_user_id !== 'string') {
      return new Response(
        JSON.stringify({ 
          error: { 
            code: 'INVALID_INPUT', 
            message: '用户ID不能为空' 
          } 
        }),
        { 
          status: 400, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    // 验证ID格式
    const userIdRegex = /^[a-zA-Z0-9_\u4e00-\u9fff-]+$/
    if (!userIdRegex.test(custom_user_id)) {
      return new Response(
        JSON.stringify({ 
          error: { 
            code: 'INVALID_FORMAT', 
            message: '用户ID只能包含字母、数字、汉字、下划线和连字符' 
          } 
        }),
        { 
          status: 400, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    // 验证ID长度
    if (custom_user_id.length < 3 || custom_user_id.length > 30) {
      return new Response(
        JSON.stringify({ 
          error: { 
            code: 'INVALID_LENGTH', 
            message: '用户ID长度必须在3-30个字符之间' 
          } 
        }),
        { 
          status: 400, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    // 检查ID是否已被其他用户使用
    const { data: existingUser, error: checkError } = await supabase
      .from('user_profiles')
      .select('id')
      .eq('custom_user_id', custom_user_id)
      .neq('id', user.id) // 排除当前用户
      .single()

    if (checkError && checkError.code !== 'PGRST116') { // PGRST116 = 没有找到记录
      console.error('检查用户ID唯一性时出错:', checkError)
      return new Response(
        JSON.stringify({ 
          error: { 
            code: 'DATABASE_ERROR', 
            message: '检查用户ID时发生错误' 
          } 
        }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    if (existingUser) {
      return new Response(
        JSON.stringify({ 
          error: { 
            code: 'ID_ALREADY_EXISTS', 
            message: '此用户ID已被其他用户使用，请选择其他ID' 
          } 
        }),
        { 
          status: 409, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    // 更新用户资料
    const { data: updatedProfile, error: updateError } = await supabase
      .from('user_profiles')
      .update({ 
        custom_user_id: custom_user_id,
        updated_at: new Date().toISOString()
      })
      .eq('id', user.id)
      .select()
      .single()

    if (updateError) {
      console.error('更新用户资料时出错:', updateError)
      return new Response(
        JSON.stringify({ 
          error: { 
            code: 'UPDATE_FAILED', 
            message: '更新用户ID失败' 
          } 
        }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    // 返回成功响应
    return new Response(
      JSON.stringify({ 
        data: {
          custom_user_id: updatedProfile.custom_user_id,
          updated_at: updatedProfile.updated_at,
          message: '用户ID更新成功'
        } 
      }),
      { 
        status: 200, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    )

  } catch (error) {
    console.error('边缘函数执行错误:', error)
    return new Response(
      JSON.stringify({ 
        error: { 
          code: 'INTERNAL_ERROR', 
          message: '服务器内部错误' 
        } 
      }),
      { 
        status: 500, 
        headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
      }
    )
  }
})
