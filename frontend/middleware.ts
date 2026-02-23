import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

const CANONICAL_HOST = 'nebula-technologies.net';

export function middleware(request: NextRequest) {
  const hostHeader = request.headers.get('host');
  const hostname = hostHeader?.split(':')[0]?.toLowerCase();

  if (hostname === `www.${CANONICAL_HOST}`) {
    const url = request.nextUrl.clone();
    url.hostname = CANONICAL_HOST;
    url.protocol = 'https:';
    return NextResponse.redirect(url, 308);
  }

  return NextResponse.next();
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
};

