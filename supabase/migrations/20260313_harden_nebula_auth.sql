revoke execute on function public.get_email_by_nebula_id(text) from public, anon, authenticated;

revoke execute on function public.get_user_binding_status(uuid) from public, anon;
grant execute on function public.get_user_binding_status(uuid) to authenticated, service_role;

revoke execute on function public.bind_contact_method(text, text, text, inet, text) from public, anon;
grant execute on function public.bind_contact_method(text, text, text, inet, text) to authenticated, service_role;

revoke execute on function public.unbind_contact_method(text, text, inet, text) from public, anon;
grant execute on function public.unbind_contact_method(text, text, inet, text) to authenticated, service_role;
