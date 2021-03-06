# H2O GBM script version 1

library(caret)
library(plyr)
library(dplyr)
library(data.table)  
library(h2o)

cat("reading the train and test data (with data.table) \n")
train <- fread("../data/train.csv",stringsAsFactors = T)
test  <- fread("../data/test.csv",stringsAsFactors = T)
store <- fread("./input/store.csv",stringsAsFactors = T)
train <- train[Sales > 0,]  ## We are not judged on 0 sales records in test set


## create stratified folds for cross-validation
# folds <- createFolds(factor(store$Store), k = 10, list = FALSE)
# store$fold <- folds
# ddply(store, 'fold', summarise, prop=mean(store$fold)/10)

train <- merge(train,store,by="Store")
test <- merge(test,store,by="Store")

# cat("train data column names and details\n")
# summary(train)
# cat("test data column names and details\n")
# summary(test)

## more care should be taken to ensure the dates of test can be projected from train
## decision trees do not project well, so you will want to have some strategy here, if using the dates
train[,Date:=as.Date(Date)]
test[,Date:=as.Date(Date)]

# competition feature
train$Competition <- (sqrt(max(train$CompetitionDistance, na.rm = TRUE)-train$CompetitionDistance))*
  (((train$year - train$CompetitionOpenSinceYear) * 12) - (train$CompetitionOpenSinceMonth-train$month))

test$Competition <- (sqrt(max(test$CompetitionDistance, na.rm = TRUE)-test$CompetitionDistance))*
  (((test$year - test$CompetitionOpenSinceYear) * 12) - (test$CompetitionOpenSinceMonth-test$month))

str(train)
str(test)

# Set appropriate variables to factors
for (j in c("Store", "DayOfWeek", "Promo", 
            "year", "month", 
#            "day", "day_of_year", "week_of_year", "PromoFirstDate",
#            "State", "PromoSecondDate", "DayBeforeClosed", "DayAfterClosed",
            "CompetitionOpenSinceMonth", "CompetitionOpenSinceYear",
            "Promo2", "Promo2SinceWeek", "Promo2SinceYear"
)) {
  train[[j]] <- as.factor(train[[j]])
  test[[j]]  <- as.factor(test[[j]])
}


## log transformation to not be as sensitive to high sales
## decent rule of thumb: 
##     if the data spans an order of magnitude, consider a log transform
train[,logSales:=log1p(Sales)]
str(train)
str(test)

## Use H2O's random forest
## Start cluster with all available threads
h2o.init(nthreads=-1,max_mem_size='5G', assertion = FALSE)

# create validation and training set
# trainHex<-as.h2o(train[year <15 | month <6,],destination_frame = "trainHex")
# validHex<-as.h2o(train[year == 15 & month >= 6,],destination_frame = "validHex")
# dim(trainHex); dim(validHex)

## Load data into cluster from R
trainHex<-as.h2o(train)
features<-names(train)[!(names(train) %in% c("Id","Date","Sales","logSales", "Customers"))]
features
####################################################################################
gbmHex <- h2o.gbm(x=features,
                  y="logSales",
                  training_frame=trainHex,
                  model_id="introGBM",
                  nbins_cats=1115,
                  sample_rate = 0.5,
                  col_sample_rate = 0.5,
                  max_depth = 15,
                  learn_rate=0.05,
                  seed = 12345678, #Seed for random numbers (affects sampling) - Note: only reproducible when running single threaded
                  ntrees = 50)

summary(gbmHex)
(varimps = data.frame(h2o.varimp(gbmHex)))

####################################################################################
features2 = varimps$variable[1:100]

gbmHex2 <- h2o.gbm( x=features2,
                    y="logSales",
                    training_frame=trainHex,
                    model_id="introGBM",
                    nbins_cats=1115,
                    sample_rate = 0.5,
                    col_sample_rate = 0.5,
                    max_depth = 15,
                    learn_rate=0.05,
                    seed = 12345678, #Seed for random numbers (affects sampling) - Note: only reproducible when running single threaded
                    ntrees = 50)

summary(gbmHex2)
(varimps2 = data.frame(h2o.varimp(gbmHex2)))

####################################################################################
temp = c(varimps2$variable[1:80], "Store", "DayOfWeek", "Promo", "year", "month", "CompetitionOpenSinceMonth", 
         "CompetitionOpenSinceYear", "Promo2", "Promo2SinceWeek", "Promo2SinceYear")
features3 = unique(temp)

gbmHex3 <- h2o.gbm( x=features3,
                    y="logSales",
                    training_frame=trainHex,
                    model_id="introGBM",
                    nbins_cats=1115,
                    sample_rate = 0.5,
                    col_sample_rate = 0.5,
                    max_depth = 20,
                    learn_rate=0.1,
                    seed = 12345678, #Seed for random numbers (affects sampling) - Note: only reproducible when running single threaded
                    ntrees = 50)

summary(gbmHex3)
(varimps3 = data.frame(h2o.varimp(gbmHex3)))

rmse = function(predictions, targets) {
  return(((predictions - targets)/targets) ** 2)
}

train_pred = as.data.frame(h2o.predict(gbmHex,trainHex))
train_pred <- expm1(train_pred[,1])
train_pred = train_pred
train$pred = train_pred
train$rmse = rmse(train_pred, train$Sales)
train2 = filter(train, month %in% c(8,9))
(total_rmse = sqrt(sum(train$rmse)/nrow(train)))
(partial_rmse = sqrt(sum(train2$rmse)/nrow(train2)))
sumup = as.data.frame(rbind(summary(train_pred), summary(train$Sales), summary(train2$pred), summary(train2$Sales)))
sumup$sd = c(round(sd(train_pred)), round(sd(train$Sales)), round(sd(train2$pred)), round(sd(train2$Sales)))
sumup


cat("Predicting Sales\n")
## Load test data into cluster from R
testHex<-as.h2o(test)

## Get predictions out; predicts in H2O, as.data.frame gets them into R
predictions<-as.data.frame(h2o.predict(gbmHex3,testHex))
## Return the predictions to the original scale of the Sales data
pred <- expm1(predictions[,1])
summary(pred)
submission <- data.frame(Id=test$Id, Sales=pred)
cat("saving the submission file\n")
write.csv(submission, "./H2O_submits/h2o_GBM_20_10_50.csv",row.names=F)

