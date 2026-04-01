// 获取用户资料的边缘函数
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { getCorsHeaders } from '../_shared/security.ts'
import {
  buildUserProfileSyncPatch,
  getAuthProfileSnapshot,
  mergeUserProfileRecord
} from '../_shared/auth-profile.ts'

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
    
    // 创建Supabase客户端
    const supabase = createClient(supabaseUrl, supabaseServiceKey)

    // 验证HTTP方法
    if (req.method !== 'GET') {
      return new Response(
        JSON.stringify({ 
          error: { 
            code: 'METHOD_NOT_ALLOWED', 
            message: '只支持GET方法' 
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

    // 获取用户资料
    const { data: profile, error: profileError } = await supabase
      .from('user_profiles')
      .select(`
        id,
        email,
        custom_user_id,
        nebula_id,
        constellation,
        constellation_name,
        constellation_description,
        account_type,
        phone,
        full_name,
        avatar_url,
        created_at,
        updated_at
      `)
      .eq('id', user.id)
      .single()

    const authSnapshot = getAuthProfileSnapshot(user)
    const { data: usersRow } = await supabase
      .from('users')
      .select('nebula_id')
      .eq('id', user.id)
      .maybeSingle()
    const usersRowNebulaId =
      typeof usersRow?.nebula_id === 'string' && usersRow.nebula_id.trim().length > 0
        ? usersRow.nebula_id.trim()
        : null
    const canonicalNebulaId =
      authSnapshot.metadataNebulaId ||
      usersRowNebulaId ||
      (typeof profile?.nebula_id === 'string' && profile.nebula_id.trim().length > 0
        ? profile.nebula_id.trim()
        : null)

    const mergeProfile = (rawProfile: Record<string, unknown>) =>
      mergeUserProfileRecord(rawProfile, user, canonicalNebulaId)

    if (profileError) {
      console.error('获取用户资料时出错:', profileError)
      
      // **修复**: 如果用户资料不存在，创建一个基本资料，但不覆盖 created_at
      if (profileError.code === 'PGRST116') {
        console.log('User profile not found, creating basic profile for user:', user.id)
        
        const { data: newProfile, error: createError } = await supabase
          .from('user_profiles')
          .insert({
            id: user.id,
            ...mergeProfile({
              id: user.id,
              email: null,
              phone: null,
              account_type: null,
              nebula_id: null,
              full_name: null,
              avatar_url: null,
              constellation: user.user_metadata?.constellation ?? null,
              constellation_name: user.user_metadata?.constellation_name ?? null,
              constellation_description: user.user_metadata?.constellation_description ?? null
            })
          })
          .select(`
            id,
            email,
            custom_user_id,
            nebula_id,
            constellation,
            constellation_name,
            constellation_description,
            account_type,
            phone,
            full_name,
            avatar_url,
            created_at,
            updated_at
          `)
          .single()
        
        if (createError) {
          console.error('创建用户资料时出错:', createError)
          return new Response(
            JSON.stringify({ 
              error: { 
                code: 'PROFILE_CREATE_FAILED', 
                message: '创建用户资料失败' 
              } 
            }),
            { 
              status: 500, 
              headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
            }
          )
        }
        
        return new Response(
          JSON.stringify({ data: mergeProfile(newProfile) }),
          { 
            status: 200, 
            headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
          }
        )
      }
      
      return new Response(
        JSON.stringify({ 
          error: { 
            code: 'PROFILE_FETCH_FAILED', 
            message: '获取用户资料失败' 
          } 
        }),
        { 
          status: 500, 
          headers: { ...corsHeaders, 'Content-Type': 'application/json' } 
        }
      )
    }

    if (!authSnapshot.metadataNebulaId && canonicalNebulaId) {
      const { error: authSyncError } = await supabase.auth.admin.updateUserById(user.id, {
        user_metadata: {
          ...(user.user_metadata ?? {}),
          nebula_id: canonicalNebulaId
        }
      })

      if (authSyncError) {
        console.warn('同步 nebula_id 到 auth metadata 失败:', authSyncError)
      }
    }

    if (canonicalNebulaId && canonicalNebulaId !== usersRowNebulaId) {
      const { error: usersSyncError } = await supabase
        .from('users')
        .update({
          nebula_id: canonicalNebulaId,
          updated_at: new Date().toISOString()
        })
        .eq('id', user.id)

      if (usersSyncError) {
        console.warn('同步 nebula_id 到 users 表失败:', usersSyncError)
      }
    }

    const syncPatch = buildUserProfileSyncPatch(profile, user, canonicalNebulaId)
    if (Object.keys(syncPatch).length > 0) {
      const { error: syncError } = await supabase
        .from('user_profiles')
        .update({
          ...syncPatch,
          updated_at: new Date().toISOString()
        })
        .eq('id', user.id)

      if (syncError) {
        console.warn('同步 auth metadata 到 user_profiles 失败:', syncError)
      }
    }

    // 返回用户资料
    return new Response(
      JSON.stringify({ data: mergeProfile(profile) }),
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
