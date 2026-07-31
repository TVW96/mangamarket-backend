import { Module } from '@nestjs/common';
import { AppController } from './app.controller';
import { AppService } from './app.service';
import { UserController } from './user/user.controller';
import { ProductModule } from './product/product.module';
import { ListingModule } from './listing/listing.module';

@Module({
  imports: [ProductModule, ListingModule],
  controllers: [AppController, UserController],
  providers: [AppService],
})
export class AppModule {}
