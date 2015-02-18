SparkleFormation.build do
  set!('AWSTemplateFormatVersion', '2010-09-09')

  parameters(:chef_validator_key_bucket) do
    type 'String'
  end

  resources(:chef_validator_key_bucket_policy) do
    type 'AWS::S3::BucketPolicy'
    properties do
      policy_document do
        version '2008-10-17'
        id 'ReadPolicy'
        statement _array(
          -> {
            sid 'ReadAccess'
            action [ 's3:GetObject' ]
            effect 'Allow'
            resource join!(
              "arn:aws:s3:::",
              ref!(:chef_validator_key_bucket),
              "/*"
            )
            principal do
              a_w_s attr!(:cfn_user, :arn)
            end
          }
        )
      end
      bucket ref!(:chef_validator_key_bucket)
    end
  end
end