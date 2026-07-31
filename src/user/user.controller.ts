import {
  Controller,
  Get,
  Post,
  HttpCode,
  Header,
  Redirect,
  Query,
  Param
} from '@nestjs/common';

@Controller('user')
export class UserController {
  ////////// Response headers. /////////
  @Post()
  @HttpCode(204) // No Content
  @Header('Cache-Control', 'no-store') // custom response header
  create(): string {
    return 'This action adds a new user';
  }

  @Get()
  findAll(): string {
    return 'This action returns all users';
  }

  /////////// Redirection.  ////////////
  @Get('redirect')
  @Redirect('https://nestjs.com', 301) // two optional arguments (url, statuscode)
  getDocs(@Query('version') version) {
    if (version && version == '5') {
      return { url: 'https://docs.nestjs.com/v5' };
    }
  }
  redirect() {}

  /////////// Route Parameters. ////////
  // Hint
  // Routes with parameters should be declared after any static paths.
  // This prevents the parameterized paths from intercepting traffic destined for the static paths.
  @Get(':id')
  findOne(@Param('id') id: string): string {
    console.log(id);
    return `This action returns a #${id} user`;
  }

  //////////// Route Wildcards ///////
  ////////////////////////////////////
  // Pattern-based routes are also supported in NestJS.
  // For example, the asterisk (*) can be used as a wildcard to match any combination of characters in a route at the end of a path.
  // In the following example, the findAll() method will be executed for any route that starts with abcd/,
  // regardless of the number of characters that follow.
  //   @Get('abcd/*')
  //   findAll() {
  //     return 'This route uses a wildcard';
  //   }
  // The 'abcd/*' route path will match abcd/, abcd/123, abcd/abc, and so on. The hyphen ( -) and the dot (.) are interpreted literally by string-based paths.
  // This approach works on both Express and Fastify. However, with the latest release of Express (v5), the routing system has become more strict.
  // In pure Express, you must use a named wildcard to make the route work—for example, abcd/*splat, where splat is simply the name of the wildcard parameter and has no special meaning.
  // You can name it anything you like. That said, since Nest provides a compatibility layer for Express, you can still use the asterisk (*) as a wildcard.
  // When it comes to asterisks used in the middle of a route, Express requires named wildcards (e.g., ab{*splat}cd), while Fastify does not support them at all.
}
