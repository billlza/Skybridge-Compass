import { createClient } from '@supabase/supabase-js'

const supabaseUrl = 'https://hloqytmhjludmuhwyyzb.supabase.co'
const supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imhsb3F5dG1oamx1ZG11aHd5eXpiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTUzNTE3ODUsImV4cCI6MjA3MDkyNzc4NX0.xmDCgBo5IpDlzIerIz7y2jruh34MEYrtcepeK3x_HT0'

const supabase = createClient(supabaseUrl, supabaseAnonKey)

async function createTestUser() {
  try {
    // 创建测试用户
    const { data, error } = await supabase.auth.signUp({
      email: 'testuser@nebula.internal',
      password: 'password123',
      options: {
        data: {
          nebula_id: 'TESTUSER123',
          account_type: 'nebula',
          email_verified: true,
          constellation_id: 1
        }
      }
    })

    if (error) {
      console.error('Error creating test user:', error.message)
    } else {
      console.log('Test user created successfully:', data)
    }
  } catch (err) {
    console.error('Exception:', err)
  }
}

createTestUser()
