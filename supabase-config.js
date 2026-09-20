// Supabase project connection.
// The anon key is safe to expose in client-side code — access is controlled
// by Row Level Security (RLS) policies defined in schema.sql.
const SUPABASE_URL = 'https://sqziwyfefbrkskgttglq.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InNxeml3eWZlZmJya3NrZ3R0Z2xxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcyNTEwMzQsImV4cCI6MjEwMjgyNzAzNH0.q5C94S5KVEXMBEnkTi-Qvmmn2AvjChcisEQ3mNkIWDA';

const supabaseClient = typeof window !== 'undefined'
  ? window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY) : null;
// The server uses the same public anon key and the requesting user's JWT, never a service-role key.
if (typeof module !== 'undefined') module.exports = { SUPABASE_URL, SUPABASE_ANON_KEY };
