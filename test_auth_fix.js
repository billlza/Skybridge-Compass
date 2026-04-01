// 测试修复后的认证功能
import { createClient } from '@supabase/supabase-js';

// 使用系统摘要中的 Supabase 凭据
const supabaseUrl = 'https://hloqytmhjludmuhwyyzb.supabase.co';
const supabaseKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhsb3F5dG1oamx1ZG11aHd5eXpiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTUzNTE3ODUsImV4cCI6MjA3MDkyNzc4NX0.xmDCgBo5IpDlzIerIz7y2jruh34MEYrtcepeK3x_HT0';

const supabase = createClient(supabaseUrl, supabaseKey);

async function testEmailValidation() {
  console.log('测试修复后的邮箱验证...\n');
  
  // 测试修复前的无效邮箱（应该失败）
  console.log('1. 测试无效邮箱 (cancer@nebula.demo):');
  try {
    const invalidResult = await supabase.auth.signUp({
      email: 'cancer@nebula.demo',
      password: 'testpassword123',
      options: {
        data: {
          constellation: 'Cancer'
        }
      }
    });
    if (invalidResult.error) {
      console.log('✅ 预期的错误:', invalidResult.error.message);
    } else {
      console.log('❌ 意外成功，应该失败');
    }
  } catch (error) {
    console.log('✅ 预期的异常:', error.message);
  }
  
  console.log('\n2. 测试修复后的有效邮箱 (cancer@gmail.com):');
  try {
    const validResult = await supabase.auth.signUp({
      email: 'cancer@gmail.com',
      password: 'Lza20020719',
      options: {
        data: {
          constellation: 'Cancer',
          constellation_name: 'Cancer 巨蟹座',
          constellation_description: '守护关怀与保护'
        }
      }
    });
    
    if (validResult.error) {
      console.log('❌ 注册失败:', validResult.error.message);
    } else {
      console.log('✅ 注册成功!');
      console.log('用户 ID:', validResult.data.user?.id);
      console.log('邮箱:', validResult.data.user?.email);
      console.log('确认状态:', validResult.data.user?.email_confirmed_at ? '已确认' : '待确认');
      
      // 测试登录
      console.log('\n3. 测试登录:');
      const loginResult = await supabase.auth.signInWithPassword({
        email: 'cancer@example.com',
        password: 'Lza20020719'
      });
      
      if (loginResult.error) {
        console.log('❌ 登录失败:', loginResult.error.message);
      } else {
        console.log('✅ 登录成功!');
        console.log('Session ID:', loginResult.data.session?.access_token.substring(0, 20) + '...');
      }
    }
  } catch (error) {
    console.log('❌ 异常:', error.message);
  }
}

testEmailValidation().then(() => {
  console.log('\n测试完成！');
}).catch(console.error);
